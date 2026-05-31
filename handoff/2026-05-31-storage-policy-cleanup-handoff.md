# Handoff: Storage Policy + GitOps Cleanup

**Date:** 2026-05-31 (end of session)
**Audience:** the next operator / Codex
**Prior context (read these first):**
- `handoff/2026-05-29-longhorn-cross-pool-resilience.md` — the original cross-pool architecture decision
- `handoff/2026-05-30-cross-pool-replica-anti-affinity-spike.md` — the spike that validated N=3 + soft anti-affinity
- `handoff/2026-05-30-cross-pool-migration-complete.md` — the `yov` migration result and methodology lessons

This handoff covers what happened on **2026-05-31** (the flash-saturation incident and aftermath) and points at the **plan + bd structure** that the cleanup work resumes from. The plan file lives at `~/.claude/plans/there-are-some-recent-moonlit-hamster.md` on the workstation. The whole story is also captured in this doc.

---

## TL;DR

1. The cluster was put through a flash-pool-IOPS storm today. Root-caused, triaged, and the immediate fire is out. **Cluster is stable** (worker-2 load 4-24, no app loops).
2. The triage involved a lot of `kubectl patch` and a few `ignoreDifferences` entries that don't have a clean GitOps source. **There is drift.** The user wants it cleaned up properly.
3. **A 6-phase cleanup plan** is staged in bd under umbrella `home-infra-wdy`, broken into 11 sub-issues. Phase 1 (policy doc) is the only one in `bd ready` — everything else is gated on it.
4. **A specific policy table is proposed** in the plan; the user will review and tune it during the cleanup session.
5. The cleanup session **should not start by patching anything live**. It should start by codifying the policy, then building the audit script, then doing PVC recreations wave-by-wave.

---

## Cluster state at handoff time

| Thing | State |
|---|---|
| Worker-2 host load | ~24 (was 528 during the storm; recovered) |
| Worker-2 I/O pressure | ~9-50% (was 96%) |
| `/dev/sdb` (worker-2's view of flash) | ~19% busy steady-state (was 100%) |
| Atlas `pve/data` thin pool | 77.99% (was 97.55% pre-discard-rollout; alert cleared) |
| Vault | All 3 pods unsealed, raft-2 active leader (rotated from raft-1 during storm) |
| Grafana | 3/3 Running, stable |
| Prometheus | 2/2 Running, stable |
| Longhorn IMs | All 7 Running, 0 restarts |
| Degraded volumes | 2 (plex-config-rdn rebuilding tank replica, sparkyfitness-database-backup detached — expected) |
| ArgoCD apps OutOfSync | gatus, memos, root-prod, vpa-targets (all manual-sync, all intentional) |
| ProxmoxThinPoolDataHigh alert | Cleared |
| LonghornBackupStale alerts | 8 still firing (4 from storm, will retry next cron; 4 are unlabeled-volume edge cases) |
| Active critical alerts | None |

**Latest commit on `main`:** `b1394c5 chore(beads): file storage policy + cleanup umbrella structure`

---

## What happened today (2026-05-31) — story version

### Morning: discovered yesterday's `yov` work overcommitted the flash pool

`yov` (2026-05-30) bumped 25 misplaced Longhorn volumes from N=2 to N=3 with cross-pool placement. This was the correct design for **failure resilience** (a flash incident now leaves a tank replica live) but **wrong for the sustained-IOPS budget** of the shared physical flash pool on Atlas.

The shared physical flash pool is two UDSS SSDs (`/dev/sdf` + `/dev/sdg`) in a ZFS mirror, exposed to all 4 worker VMs via QEMU. Each worker thinks it has its own flash disk; they share the same physical spindles. yov added ~25 active flash replicas to that shared pool's working set. The cluster ran fine for 14 hours, then steady-state writes pushed flash past the saturation line and cascade started.

### The storm

- Multiple Longhorn replicas timed out on flash
- After `replica-replenishment-wait-interval` (600s default) elapsed, Longhorn started rebuilds
- Rebuilds also needed flash IOPS → competed with normal workload → no progress (0 MB/s observed)
- Vault re-sealed twice (raft pods couldn't get fast-enough disk to maintain heartbeat)
- Grafana started a crash loop (SQLite operations timed out → liveness failed → pod killed)
- Prometheus started a crash loop (same)

### Triage actions taken

In order, with the reasoning:

1. **Bumped `replica-replenishment-wait-interval` to 3600s.** Stops new rebuild attempts from being queued for an hour while we figure out what's wrong.
2. **Deleted ~7 stuck "rebuilding" replicas** (in `WO` mode) across multiple volumes. They were burning flash IOPS without making progress.
3. **Moved heavy writers to tank-only via runtime `kubectl patch volume <name> --type=merge -p '{"spec":{"diskSelector":["tank"]}}'`:**
   - `paperless-db`
   - `pvc-5657f3e2-...` (Prometheus)
   - `pvc-72152608-...` (Loki)
   - `pvc-ce6b033f-...` (Plex config, on `longhorn-redundant` SC)
   - `data-vault-raft-0`, `data-vault-raft-2`, `pvc-3d464534-...` (vault-raft-1)
4. **Reverted Vault PVCs N=3 → N=1** to match their SC's documented design. Memory `vault-pvc-must-stay-n1` saved during today's session captures why: the vault `longhorn-vault-raft` SC explicitly sets `numberOfReplicas: 1` because Vault has app-level raft replication and Longhorn-level replication causes rebuild storms during disk churn. yov violated this. Today reverted it.
5. **Reset wait interval back to 600s** once the flash pool was breathing again (~20% busy).

By the time the storm subsided, worker-2 load was back to single digits and the apps were stable.

### Side issue surfaced: `pve/data` 97.55% full (critical Proxmox alert)

This is the home-infra-f7k issue and was already at 97.55% before today's events (just escalated to critical at some point). Triage:

1. Discovered the k3s VM `scsi0` OS disks were created without `discard=on`, so `fstrim` inside guests was a no-op against the underlying LVM thin pool.
2. Fixed and rebooted CPs one at a time:
   - `qm set <vmid> --scsi0 local-lvm:vm-<vmid>-disk-0,discard=on,<other-options>` (preserve other options)
   - `qm reboot <vmid>`
   - wait Ready
   - `fstrim -av` on the guest
3. **CP rollout result:** `pve/data` went from 97.55% → 89.75% → 84.87% → 77.99% (~78 GiB freed across cp-1, cp-2, cp-3). `ProxmoxThinPoolDataHigh` alert cleared.
4. **Worker rollout deferred to a maintenance window.** Workers (`vm-101` = worker-1, `vm-103` = worker-2, `vm-105` = worker-3, `vm-107` = worker-gpu-1) each need `cordon → drain → qm set discard=on → qm reboot → fstrim → uncordon` and that's a 10-15 min disruption per worker. Documented in `home-infra-f7k` notes.

### New monitoring artifact

Added 4 per-drive panels to the Proxmox Hosts Grafana dashboard
(`argocd/manifests/monitoring-config/base/grafana-dashboard-proxmox-hosts.yaml`, commit `7abc14b`):

- **Atlas Physical Drives — Utilization (%busy)** — the headline metric for catching saturation
- **Atlas Flash Pool — Per-Drive Throughput** — sdf + sdg (UDSS SSDs)
- **Atlas Tank Pool — Per-Drive Throughput** — sda-sdd (WD Red HDDs)
- **Atlas Physical Drives — IOPS**

Use these to set the "heavy writer" threshold when writing the policy doc (Phase 1).

### Backup-coverage audit + fixes

Discovered 8 PVCs without Longhorn backup labels:

| PVC | Fix applied today | Notes |
|---|---|---|
| `data-vault-raft-1` | Replaced typo `recurringjob.group.longhorn.io/hourly` with the 4 correct labels (matches raft-0 and raft-2). | Was silently excluded from backups for an unknown duration. |
| `private-app/private-app-config-pvc` | Added `daily` + `weekly` labels. | private-app manifests are in a private repo not in this codebase. |
| 4× sparkyfitness PVCs (`data-sparkyfitness-postgresql-0`, `sparkyfitness-server-uploads`, `sparkyfitness-server-backup`, `sparkyfitness-database-backup`) | Added `daily` + `weekly` labels. Chart doesn't support label injection. Added `ignoreDifferences` on the sparkyfitness Application so ArgoCD doesn't strip them. Also added `/spec/storageClassName` to that ignore block (the chart values say `longhorn-tank` for backup PVCs but live is `longhorn` and PVC SC is immutable — same pattern as paperless-db). | Future-proper fix: PVC recreation under Phase 4 Wave 5. |
| `monitoring/storage-loki-0` | No backup labels by design (logs are operational, ephemeral). | Verify intent in policy doc. |
| `memos/memos-data-v3-pvc` | No backup labels by intent (memos workaround per `memos-workaround-2026-05-29`). | Verify intent in policy doc. |

### ArgoCD sync cleanup

Today also resolved several lingering ArgoCD `OutOfSync` cases that pre-dated this session:

- **paperless**: added `ignoreDifferences` on `paperless-db-pvc /spec/storageClassName` (chart says `longhorn-tank`, live says `longhorn`, immutable). Synced.
- **kube-prometheus-stack** + **loki**: chart values were briefly changed to `longhorn-tank` then reverted to `longhorn` because StatefulSet `volumeClaimTemplates` is immutable. The runtime `diskSelector: ["tank"]` on the Volume CR is what actually controls placement. Inline comments in the chart values explain this.
- **memos**: source manifest had `syncPolicy.automated` but the live Application was manually de-automated (intentional pause per the SIGBUS issue). Aligned the manifest to match (`syncPolicy.syncOptions: [CreateNamespace=true]` only, no `automated:`). The drift cleared.
- **sparkyfitness**: synced the app to recreate the `sparkyfitness-database-backup` PVC that had been stuck Terminating since 2 days ago.
- **root-prod**: was failing to sync because `memos` resource update kept hitting a `resourceVersion=0` patch error. Cleared by removing the stale `kubectl.kubernetes.io/last-applied-configuration` annotation on the memos Application, then resyncing.

---

## Drift summary — what's still NOT clean

This is the cleanup backlog. Every item below should ultimately resolve under `home-infra-wdy` (the umbrella):

### Runtime patches with no manifest source

6 Volume CRs have `spec.diskSelector: ["tank"]` patched live. No chart or manifest expresses this. ArgoCD doesn't see drift because the patch is on the Volume CR (Longhorn-internal), not on the PVC (k8s native). But it IS drift between intent and live state.

- `pvc-ce6b033f-...` (plex-config-rdn on `longhorn-redundant` SC)
- `pvc-5657f3e2-...` (Prometheus on `longhorn` SC)
- `pvc-72152608-...` (Loki on `longhorn` SC)
- `paperless-db` (chart says `longhorn-tank` but PVC bound to `longhorn`)
- `data-vault-raft-0/1/2` (on `longhorn-vault-raft` SC; SC has no diskSelector but volumes do at runtime — possibly redundant but not declared)

**Cleanup path:** PVC recreation. Each volume's new PVC is bound to a manifest-declared SC that has the right `diskSelector` baked in. The runtime patch goes away because the SC itself enforces placement.

### `ignoreDifferences` entries

Listed in detail in the plan; the short version:

- `argocd/apps/prod/paperless.yaml` — `/spec/storageClassName` on `paperless-db-pvc`. Will go away when Wave 5 recreates the PVC.
- `argocd/apps/prod/sparkyfitness.yaml` — labels + `/spec/storageClassName`. Will go away when Wave 5 recreates the 2 backup PVCs.
- `argocd/apps/prod/vault.yaml` — StatefulSet `volumeClaimTemplates/0/metadata/labels`. This one is more durable; StatefulSet VCT is immutable, so the labels we added at runtime on `data-vault-raft-1` will need similar handling on any future PVC recreation. Acceptable, but document why.

### Helm chart values that don't match live

- `argocd/apps/prod/kube-prometheus-stack.yaml` — Prometheus volumeClaimTemplate `storageClassName: longhorn`. Policy target is `longhorn-tank`. Can't change in place. Wave 7 recreates.
- `argocd/apps/prod/loki.yaml` — same. Wave 7.
- `argocd/apps/prod/sparkyfitness.yaml` — `server.persistence.backup.storageClass: longhorn-tank`, `databaseBackup.persistence.storageClass: longhorn-tank`, live PVCs on `longhorn`. Wave 5.

### Inconsistent `numberOfReplicas`

Default SC says N=3 but the volume population is mixed:
- N=1: vault-raft-* (correct per `longhorn-vault-raft` SC)
- N=2: most pre-yov legacy volumes
- N=3: post-yov migrated volumes

`numberOfReplicas` is per-volume, set at creation. Each volume's number can only be changed by manual patch (which we don't want) or PVC recreation (Phase 4 sweep aligns each volume to its policy class).

### Stale documentation

`argocd/manifests/longhorn-storage-classes/README.md` still says the default SC is N=2 — it's been N=3 since `home-infra-rd0` landed on 2026-05-30. Phase 3 quick fix.

### Out-of-band labels

- `private-app-config-pvc` labels exist only at runtime; private-app manifests are in a private repo (per memory `private-apps-public-repo`). Document this as the source-of-truth note in the policy doc; can't fix in this repo.
- The vault-raft-1 label fix from today: the chart's `dataStorage.labels` is correct (`recurring-job-group.longhorn.io/hourly|daily|weekly` + `recurring-job.longhorn.io/source`). The typo'd label on the live PVC was a manual artifact, now corrected. New PVCs from the chart would have the correct labels.

### Pending operational work (not blocking the cleanup, but track)

- **`pve/data` worker rollout** — `home-infra-f7k` notes have the per-worker procedure (cordon/drain + qm set discard=on + reboot + fstrim). Each worker reboot needs a maintenance window.
- **4 stale Longhorn backup alerts** (`private-app-config`, `nzbget-config`, `jellyseerr-config`, `netbootxyz-data`) — last successful backup ~2 days ago, during the storm period. Should clear on next hourly cron unless there's a deeper issue.
- **4 unlabeled stale-backup alerts** — actually never-backed-up volumes that the alert rule's `> 0` check edge-cases. Could be fixed by tightening the rule or labeling the volumes; see `home-infra-95b` (the policy doc) for the decision.

---

## The cleanup plan — phase summary

Full plan: `~/.claude/plans/there-are-some-recent-moonlit-hamster.md` (workstation), or read the bd issue descriptions.

| Phase | bd issue | Output | Blocks |
|---|---|---|---|
| Phase 1 | `home-infra-95b` | `docs/operations/storage-policy.md` — proposed policy table from plan, user reviews | Phases 2 + 3 |
| Phase 2 | `home-infra-4l5` | `scripts/maintenance/audit-storage-policy.sh` — gate-script that exits 0 when cluster matches policy | Wave 1 onward |
| Phase 3 | `home-infra-kd3` | README fix, longhorn-redundant SC alignment, push labels into chart values where possible, drop `ignoreDifferences` as waves resolve drift | Parallel with waves |
| Phase 4 Wave 1 | `home-infra-xvx` | Recreate cache PVCs (immich-model-cache, hoarder-meilisearch) — confidence-build | Wave 2 |
| Phase 4 Wave 2 | `home-infra-hgf` | Small read-mostly (notemark, snippetbox, linkding, ntfy, wallos) | Wave 3 |
| Phase 4 Wave 3 | `home-infra-qop` | *arr configs (radarr, sonarr, prowlarr, private-arr, nzbget) | Wave 4 |
| Phase 4 Wave 4 | `home-infra-h7x` | App-state (bookstack, factorio, paperless data/media/export, changedetection, firefox) | Wave 5 |
| Phase 4 Wave 5 | `home-infra-e8o` | DBs (paperless-db, librechat-mongodb, immich-db, bookstack-db-data, sparkyfitness postgres) | Wave 6 |
| Phase 4 Wave 6 | `home-infra-xs4` | Single-pod no-HA (grafana, jellyfin-config, plex-config-rdn) | Wave 7 |
| Phase 4 Wave 7 | `home-infra-8ca` | Prometheus + Loki TSDB (chart values can change because the StatefulSet's PVCs get recreated as part of the wave) | Wave 8 |
| Phase 4 Wave 8 | `home-infra-8o5` | Vault raft (P1) — one pod at a time, leader last, verify quorum between | — |

**Sequence: 95b → (4l5 + kd3) → xvx → hgf → qop → h7x → e8o → xs4 → 8ca → 8o5 → wdy closes.**

`bd ready` at the start of the cleanup session will show `home-infra-95b` as the entry point (plus pre-existing P1s on other concerns: `13o` restore retries, `2oj` memos, `dil` SLOG, `f7k` pve/data — those are independent and not part of this cleanup).

---

## The proposed policy (draft, in the plan)

| App class | SC | replicas | Backup groups |
|---|---|---|---|
| Vault raft member | `longhorn-vault-raft` | 1 | hourly+daily+weekly |
| Heavy continuous writer (DBs/TSDBs/log stores) | `longhorn-tank` | 2 | hourly+daily+weekly (Loki skips hourly) |
| Read-fast, write-rarely | `longhorn-flash` | 2 | daily+weekly |
| Single-pod no-HA app | `longhorn-redundant` | 3 | daily+weekly |
| Catch-all | `longhorn` (default, soft cross-pool) | 3 | daily+weekly |
| Media (GPU worker, hw transcoding) | `longhorn-media` | 3 | daily+weekly |
| Pure local static | static PV | n/a | n/a |

**Decision principles to write into `docs/operations/storage-policy.md`:**

1. "Heavy writer" = sustained >X IOPS / >Y bytes/s 95th percentile — set X/Y by reading the Atlas per-drive Grafana panels (commit `7abc14b`) under normal load.
2. Replica count is a property of the SC. Volumes inherit at creation. Changing replica count = recreate the PVC.
3. `longhorn-flash` and `longhorn-tank` enforce placement via SC `diskSelector`. Every runtime `kubectl patch volume … diskSelector=tank` is a sign the PVC is on the wrong SC.
4. Labels are policy. Every PVC has explicit `recurring-job-group.longhorn.io/<group>: enabled` labels in its manifest, unless explicitly opted out with an annotation + comment naming the bd issue justifying it.
5. The default SC is for apps with no special needs. Putting a write-heavy DB there is a bug.

The Phase 1 issue (`home-infra-95b`) has all of this in its description. Start there.

---

## Recreation procedure (used by every Wave issue)

Per PVC:

1. Take a Longhorn backup (manual Backup CR, verify `state: Completed`).
2. Scale workload to 0 (`kubectl scale deployment <name> --replicas=0` or `kubectl scale statefulset <name> --replicas=0`).
3. Wait for the PVC to be unbound (no pod references it).
4. Delete the PVC. ArgoCD recreates from the (policy-aligned) manifest.
5. Restore from the backup — `scripts/maintenance/restore-app.sh` for app-aware logic where supported.
6. Scale workload back up.
7. Verify pod is healthy and `bash scripts/maintenance/audit-storage-policy.sh` ticks the row for this PVC.

**Vault special-case (Wave 8):**
- Always confirm all 3 pods unsealed before touching a PVC
- Migrate one standby at a time; verify quorum holds between
- Leader's PVC last
- Reference memory `vault-pvc-must-stay-n1` for the design rationale (N=1 by SC, app-level HA via raft)
- During today's session, `vault-raft-1` lost leader status when its pod was briefly disrupted; the cluster auto-elected raft-2 and quorum held. Expect similar behavior — that's healthy, not a problem.

**Watch out for (from this session and prior):**
- The `longhorn-batch-restore-cascade-2026-05-30` memory documents what happens when too many migrations run in a tight loop. Wait between volumes, watch IM memory + event rate.
- The audit script (Phase 2) is the gate: do not declare a wave done until the script ticks `✅` for every PVC in scope.

---

## Files / scripts to know

| Path | Purpose |
|---|---|
| `~/.claude/plans/there-are-some-recent-moonlit-hamster.md` | The plan that backs this handoff. User-approved 2026-05-31. |
| `scripts/maintenance/verify-cross-pool-placement.sh` | Existing audit script for cross-pool placement. Phase 2's new audit script (`audit-storage-policy.sh`) models on this. |
| `scripts/maintenance/migrate-volumes-to-cross-pool.sh` | Used during yov; has the `--keep-extra` flag added today for N=3 end-state migrations. Probably not needed in the cleanup (PVC recreation supersedes it). |
| `argocd/manifests/longhorn-storage-classes/` | The 3 ArgoCD-managed SCs (longhorn / longhorn-flash / longhorn-tank). The README here is stale (N=2 default — should say N=3). Phase 3 fix. |
| `argocd/manifests/longhorn-redundant-sc/` | The `longhorn-redundant` SC (N=3, nodeSelector=general-storage). Has correct recurring job selectors. |
| `argocd/manifests/vault-storageclass/` | The `longhorn-vault-raft` SC (N=1). Its inline comment explains the design — required reading. |
| `argocd/manifests/monitoring-config/base/grafana-dashboard-proxmox-hosts.yaml` | The new per-drive panels (commit `7abc14b`). Use these to inform the heavy-writer threshold in the policy doc. |
| `docs/operations/cluster-operations.md` | The Longhorn section was updated 2026-05-30. Has the cross-pool model table. Slim this down and link out to the new `storage-policy.md` once Phase 1 is done. |
| `handoff/2026-05-29-longhorn-cross-pool-resilience.md` | Original cross-pool design context. |
| `handoff/2026-05-30-cross-pool-migration-complete.md` | Methodology lessons from yov. Required reading for anyone doing PVC recreation work. |

---

## bd memories — required reading before acting

Run `bd memories <keyword>` or `bd remember --list` to fetch them. The ones most relevant to this cleanup:

- **`task-tracking-convention-for-home-infra-use-bd`** — confirms bd is the only task tracker. Do not use TodoWrite, TaskCreate, or markdown TODOs.
- **`vault-pvc-must-stay-n1`** — the vault SC says N=1 for a reason. Phase 4 Wave 8 acceptance is "no replica bumps."
- **`longhorn-sc-anti-affinity-value-format`** — the SC parameter accepts `"enabled"` / `"disabled"` / `"ignored"`, not booleans. Used during `home-infra-rd0` spike. Will matter again if anyone tweaks the default SC.
- **`longhorn-batch-restore-cascade-2026-05-30`** — methodology constraint: one PVC at a time, verify between, never chain N invasive ops in a tight loop. Especially relevant to Waves 5 + 8.
- **`cluster-wide-actions-must-be-explicit-2026-05-30`** — when proposing anything that disrupts many running workloads (restart all IMs, pause all apps, etc.), state explicitly that it'll bring most things down. Prefer targeted action.
- **`memos-workaround-2026-05-29`** — memos pinned to worker-2 with a SIGBUS-prone replica situation. Don't try to "fix" memos's storage placement without reading the issue.
- **`longhorn-im-pod-stuck-terminating-recovery`** + **`longhorn-im-restart-needs-engine-image-restart-too`** — recovery patterns if an IM pod gets stuck during PVC recreation work.
- **`private-apps-public-repo`** (feedback) — don't reference private-app, private-arr, etc. in committed files.
- **`no-claude-coauthor`** (feedback) — skip the `Co-Authored-By: Claude` trailer on commits in this repo.

---

## How to start the cleanup session

1. **Read this handoff and the plan file.** That's enough context.
2. **`bd ready`** — confirms `home-infra-95b` is the entry point. Pre-existing P1s are independent (you can pick them up or defer).
3. **`bd update home-infra-95b --claim` and start on `docs/operations/storage-policy.md`.** The Phase 1 issue description has the table + principles to draft from. Talk through the table with the user; adjust where the principles or examples don't fit.
4. Once the policy is committed and the user has signed off, **Phase 2 (`home-infra-4l5`) and Phase 3 (`home-infra-kd3`) both unblock**. The audit script (Phase 2) is the most useful deliverable — every wave's "done" gate is "the audit script ticks for these PVCs."
5. Waves run in order. Don't skip ahead. Wave 1 is the procedural smoke test before Wave 5 (DBs) or Wave 8 (Vault).

---

## Operational gotchas observed this session

- **Atlas's flash pool is two UDSS SSDs shared across all 4 worker VMs.** Per-VM I/O metrics (`/proc/diskstats` inside a worker) don't reflect the underlying physical pool. The new dashboard panels read directly from Atlas's node_exporter — use those, not the worker-side metrics, to judge flash saturation.
- **`pve/data` thin pool is `/dev/sde3` only**, 352.86G total. The VG has only 1G free. Extending the pool requires adding/freeing space first. `discard=on` + fstrim is the right reclaim strategy.
- **VM IDs do not match worker numbers.** Confirmed mapping (Atlas hosts these):
  - `vm-100` = `k3s-prod-cp-3` (172.20.20.106)
  - `vm-101` = worker-1 (172.20.20.101)
  - `vm-102` = `k3s-prod-cp-2` (172.20.20.105)
  - `vm-103` = worker-2 (172.20.20.102)
  - `vm-104` = `k3s-prod-cp-1` (172.20.20.104)
  - `vm-105` = worker-3 (172.20.20.103)
  - `vm-107` = `k3s-prod-worker-gpu-1` (172.20.20.107)
- **`discard=on` requires a VM reboot to take effect.** `qm set` marks the change pending. Verified live on cp-1, cp-2, cp-3 today; their `scsi0` configs in `/etc/pve/qemu-server/{100,102,104}.conf` now have `discard=on`. The 4 workers still need the same treatment (deferred).
- **ArgoCD `Replace=true` syncOption uses `kubectl replace` (no `--force`).** Doesn't bypass immutable fields. For SCs and StatefulSet VCTs you still need to delete the object manually or recreate the PVC. Learned during the SC adoption work; sparkyfitness `ignoreDifferences` is the workaround.

---

## Commit log for the day (newest first)

```
b1394c5 chore(beads): file storage policy + cleanup umbrella structure
485eca1 fix(argocd): also ignore PVC storageClassName drift on sparkyfitness
d30fe49 fix(argocd): ignore Longhorn backup labels drift on sparkyfitness PVCs
c544780 chore(beads): update f7k with CP discard rollout procedure (worker rollout pending)
02cdc9e chore(beads): track plex-config runtime move to tank (wdy)
7abc14b feat(monitoring): add per-drive panels to Proxmox Hosts dashboard
2aa16d0 fix(argocd): align memos Application manifest with intentional auto-sync-off
8d6fab6 revert: keep prom/loki chart SC at longhorn (immutable on StatefulSet)
98b345d fix(argocd): ignoreDifferences for immutable SC drift on paperless/prom/loki
19c9323 fix(storage): pin heavy-write apps to longhorn-tank SC (2026-05-31 incident)
```

Everything pushed to `main`.

---

## One-line summary

The flash pool got pegged because `yov` overcommitted it, triage moved heavy writers to tank via runtime patches, and now we need to codify the policy that drove those patches and align the cluster, manifests, and an audit script to it — phase-by-phase, starting with the policy doc (`home-infra-95b`).
