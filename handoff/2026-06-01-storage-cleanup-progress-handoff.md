# Handoff: Storage Cleanup Progress (Pragmatic Scope)

**Date:** 2026-06-01 (current session)
**Audience:** the next operator / Codex
**Read these first:**
- `handoff/2026-05-31-storage-policy-cleanup-handoff.md`
- `handoff/2026-05-30-cross-pool-migration-complete.md`
- `docs/operations/storage-policy.md`
- `scripts/maintenance/audit-storage-policy.sh`

This handoff picks up after the 2026-05-31 incident handoff and records what was actually completed once the cleanup was narrowed to **"worth it only"** rather than full cosmetic convergence.

---

## TL;DR

1. The storage cleanup was **rescoped**: do not migrate healthy PVCs just to rename `longhorn` to `longhorn-general` or to normalize general-purpose `N=2 -> N=3`.
2. The meaningful work through **Wave 6** is complete:
   - Wave 1 caches done
   - Wave 2 small read-mostly apps done
   - Wave 3 only `seerr` / `jellyseerr` done
   - Wave 4 closed as dormant (nothing left worth the downtime)
   - Wave 5 DB-heavy wrong-class work done
   - Wave 6 singleton/special-case cleanup done
3. Backup hygiene was completed:
   - no `LonghornBackupStale` alerts firing
   - no live policy-backed volumes missing or stale on backups
   - disconnected `Backup` and `BackupVolume` CRs pruned
4. The only meaningful storage-cleanup waves left are:
   - `home-infra-8ca` — Prometheus + Loki TSDB
   - `home-infra-8o5` — Vault raft PVCs
5. One app still needs attention before claiming full GitOps cleanliness: **`yams` is Healthy but OutOfSync**. The repo contains the intended `ignoreDifferences` for `seerr` / `jellyseerr`, but the live `Application` revision observed at handoff was still older.

---

## What Changed This Session

### Scope change

The cleanup is no longer "make every PVC perfectly canonical". The rule now is:

- keep policy / audit / backup hygiene
- fix wrong-class heavy writers
- fix runtime Longhorn patch drift where it matters
- fix singleton/special-case drift where it matters
- do **not** burn downtime on healthy general-purpose PVCs for alias cleanup alone

That pragmatic rule is reflected in:
- `docs/operations/storage-policy.md`
- `docs/operations/cluster-operations.md`
- `scripts/maintenance/storage-policy-inventory.tsv`
- `scripts/maintenance/audit-storage-policy.sh`

### Waves completed live

#### Wave 1
- `immich-model-cache-pvc`
- `hoarder-meilisearch-pvc`

Both were recreated on `longhorn-general` and now audit green.

#### Wave 2
- `notemark-data-pvc`
- `snippetbox-data-pvc`
- `linkding-data-pvc`
- `ntfy-data-pvc`
- `wallos-data-pvc`

Important lesson from Wave 2: these were **not** cache-style reprovisions. `notemark` proved the correct pattern was restore-based migration, including force-clearing stale PV objects that blocked rebinding.

#### Wave 3 (narrowed)
Only the real wrong-class cases were done:
- `yams/seerr-config-pvc`
- `yams/jellyseerr-config-pvc`

They were restored, their Longhorn volumes were patched to `diskSelector=[flash]`, and `argocd/apps/prod/yams.yaml` now carries `ignoreDifferences` for the immutable `storageClassName` drift.

#### Wave 4 (closed as dormant)
No meaningful drift remained after the rescope. App-state PVCs like `changedetection`, `factorio`, `firefox`, `paperless-data/media/export/redis` were left alone because they were already operationally fine.

#### Wave 5 (DB-heavy)
Completed meaningful DB-heavy work:
- `paperless/paperless-db-pvc`
- `immich/immich-db-pvc`
- `librechat/librechat-mongodb`
- `bookstack/bookstack-db-data-pvc`
- `sparkyfitness/data-sparkyfitness-postgresql-0`
- `sparkyfitness/sparkyfitness-database-backup`
- `sparkyfitness/sparkyfitness-server-backup`

Outcome:
- all now match their intended tank-backed policy class
- all audit green
- all corresponding apps recovered and were healthy

#### Wave 6 (singleton/special-case)
Only the meaningful singleton drift remained:
- `plex/plex-config-pvc-rdn`

This was resolved by **removing** the runtime tank-only exception and returning it to normal `longhorn-redundant` behavior. `jellyfin`, `grafana`, and `termix` were already green.

### Backup refresh + prune

This session also handled backup hygiene end-to-end:

- Manual backup refresh was run for every live policy-backed volume that was stale or missing `lastBackupAt`
- This included `sparkyfitness`
- Result: **0** live stale/missing policy-backed volumes
- Then disconnected backup history was pruned:
  - `706` disconnected `Backup` CRs deleted
  - `103` disconnected `BackupVolume` CRs deleted
- Final state after prune:
  - `LIVE_BACKUP_ISSUES = 0`
  - `DISCONNECTED_BACKUPS = 0`
  - `DISCONNECTED_BACKUPVOLUMES = 0`

### Orphaned volume cleanup

The old non-raft Vault orphan volume was investigated and removed:
- old volume: `pvc-ee3bfcbe-5a8e-4238-bdb7-4d67ba93a6d1`
- historical namespace/PVC: `vault/data-vault-0`
- status before deletion: healthy, attached in Longhorn, no current namespace or PV
- backup coverage was verified before removal
- now gone

---

## Current Audit State

Latest observed audit summary:

- Inventory rows: `68`
- Live Longhorn PVCs: `68`
- Covered by inventory: `68`
- Passing rows: `58`
- Failing rows: `10`
- Uncovered live Longhorn PVCs: `0`
- Longhorn volumes without live PVCs: `0`

Current failing rows at handoff:

- `kioto/kioto-postgres-data-pvc`
- `memos/memos-data-v3-pvc`
- `monitoring/prometheus-prometheus-prometheus-db-prometheus-prometheus-prometheus-0`
- `monitoring/storage-loki-0`
- `pocketid/pocketid-data-pvc`
- `vault-raft/data-vault-raft-{0,1,2}`
- `yams/jellyseerr-config-pvc`
- `yams/seerr-config-pvc`

Interpretation:
- The **meaningful remaining storage waves** are only Prometheus/Loki and Vault raft.
- `memos`, `pocketid`, `seerr`, and `jellyseerr` are now in the category of **accepted or separately-scoped fast-class / immutable drift**, not reasons to keep marching broad waves blindly.
- `kioto-postgres-data-pvc` is still a real heavy-writer mismatch that was not covered by the original wave sequence and needs an explicit call in a future session.

---

## App / Argo State At Handoff

Observed at handoff:
- `bookstack` — Synced / Healthy
- `paperless` — Synced / Healthy
- `immich` — Synced / Healthy
- `librechat` — Synced / Healthy
- `sparkyfitness` — Synced / Healthy
- `plex` — Synced / Healthy
- `loki` — Synced / Healthy
- `vault` — Synced / Healthy
- `yams` — **OutOfSync / Healthy**

Important nuance:
- The repo file `argocd/apps/prod/yams.yaml` already includes the intended `ignoreDifferences` for `seerr` and `jellyseerr` immutable `storageClassName` drift.
- The live `yams` `Application` was still showing an older revision at handoff, so a fresh session should check whether it just needs an apply / hard refresh or whether a different resource inside `yams` is still drifting.

---

## What Remains Meaningful

### 1. `home-infra-8ca` — Prometheus + Loki TSDB

This is the next storage wave.

Current state:
- both live PVCs still say `storageClassName: longhorn`
- both live Longhorn volumes are already runtime-patched to `diskSelector=[tank]`
- Prometheus still lacks the expected hourly backup label in the audit
- these are the largest writer volumes left

Fresh-session guidance:
- Start here if continuing storage cleanup
- Be explicit about whether Loki history is worth preserving or whether a fresh start is acceptable
- Prometheus should be preserved from backup
- Expect StatefulSet immutability issues just like prior waves

### 2. `home-infra-8o5` — Vault raft PVCs

This is the last storage wave and still the highest-risk one.

Current state:
- audit shows the Vault PVCs correct on `longhorn-vault-raft`, `N=1`, with correct backup labels
- the only remaining drift is the runtime `diskSelector=[tank]`
- this is accepted today because the incident recovery pinned them there

Fresh-session guidance:
- Only do this after `8ca`
- Leader last, one pod at a time, quorum verified between every step
- Re-read memory / rationale that Vault PVCs must stay `N=1`

### 3. Non-wave residuals

These are **not** part of the main worth-it storage wave path, but the next session should be aware of them:

- `kioto-postgres-data-pvc` still fails the audit as a heavy-writer on the wrong class
- `memos` remains governed by `home-infra-2oj`
- `pocketid` still looks like a fast-class candidate if/when you decide the downtime is worth it
- `yams` app still needs final Argo reconciliation even though `seerr` / `jellyseerr` are operationally correct

---

## Beads State To Know

Storage cleanup umbrella:
- `home-infra-wdy`

Waves / issues completed during this session chain:
- `home-infra-95b`
- `home-infra-ft7`
- `home-infra-4l5`
- `home-infra-kd3`
- `home-infra-xvx`
- `home-infra-hgf`
- `home-infra-qop`
- `home-infra-h7x`
- `home-infra-e8o`
- `home-infra-xs4`
- `home-infra-lh4`
- `home-infra-e99`

Still open / meaningful in the storage path:
- `home-infra-8ca`
- `home-infra-8o5`
- `home-infra-wdy`

Other ready issues shown by `bd ready` are **outside** this storage-cleanup path.

---

## Git / Worktree Notes

Observed during handoff:
- Branch: `storage-policy-cleanup-plan`
- Uncommitted worktree noise: `.beads/interactions.jsonl`
- There may also be unexported / freshly exported beads state depending on when the next session starts

Do not assume the dirty `.beads/interactions.jsonl` means product code drift.

The recent storage-related commit stack included:
- `e031d39 chore(beads): close singleton storage wave`
- `75971b9 fix(argocd): codify completed db storage drift`
- `4704d64 feat(storage): move bookstack-db-data to longhorn-steady for heavy writer policy`
- `3d4140a feat(argocd): add ignoreDifferences for seerr and jellyseerr storageClassName drift`
- `79d3fd3 feat(storage): move seerr and jellyseerr to longhorn-fast for read-mostly latency`

If starting fresh, inspect both `git status` and recent `git log` before assuming the branch / main relationship.

---

## Recommended Next Move

If the next session wants to continue the storage cleanup, do this:

1. Confirm `yams` app drift and clear it if it is still just the old revision / refresh problem.
2. Re-run `scripts/maintenance/audit-storage-policy.sh` and confirm the baseline still matches this handoff.
3. Start `home-infra-8ca` (Prometheus + Loki TSDB) with an explicit preservation decision for Loki history.
4. Only after `8ca`, do `home-infra-8o5` (Vault raft).

If the next session wants to switch away from storage, the storage path is in a much better place already; the only meaningful remaining waves are the two above.
