# Storage Policy

Use this document to choose a storage class, replica count, and backup cadence
for persistent workloads in the prod cluster. `cluster-operations.md` remains
the runbook; this file is the policy source of truth.

## Class Names

The policy recognizes these intent-based StorageClass names:

| Canonical name | Legacy name | Purpose |
| --- | --- | --- |
| `longhorn` | `longhorn-general` | Default 2-replica storage pinned to flash |
| `longhorn-flash` | `longhorn-fast` (retired) | Explicit flash tier for latency-sensitive state |
| `longhorn-tank` | `longhorn-steady` | Explicit tank tier for capacity/archive workloads |
| `longhorn-redundant` | `longhorn-singleton` | Single-pod state with no app-layer HA |
| `longhorn-vault-raft` | none | Vault raft members only |
| `longhorn-one-replica-flash` | none | Explicit opt-in, backup-restorable state pinned to flash |
| `longhorn-media` | none | Media workloads that must follow `media-storage` nodes |

During the cleanup, both names may exist in the cluster at the same time. The
important distinction is behavioral, not cosmetic: `longhorn` and
`longhorn-general` are equivalent general-purpose classes. Do not recreate a
healthy PVC just to switch between those two names.

## Non-Negotiables

1. StorageClass decides placement and replica count. Existing PVCs do not pick
   up later StorageClass changes. If the policy changes, recreate the PVC.
2. Backup cadence is part of the policy. Every Longhorn PVC must declare its
   `recurring-job-group.longhorn.io/*` labels in Git unless an owning bd issue
   explicitly documents why it is opted out.
3. Runtime `kubectl patch` on a Longhorn Volume CR is incident-response only.
   If a steady-state volume needs `spec.diskSelector`, `spec.numberOfReplicas`,
   or similar runtime overrides, the PVC is on the wrong StorageClass and needs
   recreation.
4. Atlas flash capacity is a shared physical mirror behind all four prod
   workers. Judge flash pressure from the Atlas per-drive Grafana panels, not
   from guest-side `/proc/diskstats`.
5. A PVC only protects data that is written to it. Every stateful workload must
   mount its PVC in the **main** container at the image's real data path. An
   init-only mount or a wrong path leaves data on the container layer: the app
   still works, backups "succeed" with an empty volume, and a restart deletes
   everything (see `docs/post-mortems/2026-10-02-outline-postgres-ephemeral-pgdata.md`).
   Verify on deploy and before any scale-down: `df -P <data path>` in the pod
   shows `/dev/longhorn/...` (not `overlay`), and a marker written to the
   database survives a pod delete.

## Decision Table

| App class | Use when | StorageClass | Replicas | Backup labels | Notes |
| --- | --- | --- | --- | --- | --- |
| Vault raft member | A pod is already part of an app-level consensus set | `longhorn-vault-raft` | 1 | hourly + daily + weekly | Vault gets HA from raft, not from Longhorn replicas. Keep the PVC single-replica. |
| Heavy continuous writer | The workload is a database, TSDB, or log store, or normal load shows sustained write pressure above about 200 write IOPS or 5 MiB/s at the 95th percentile | `longhorn-tank` | 2 | hourly + daily + weekly | Use for PostgreSQL, MongoDB, and similar steady writers. Loki may skip hourly if log-history loss is acceptable. Prometheus is a measured exception documented below. |
| Latency-sensitive state | The workload benefits from low latency or uses SQLite/small-file metadata | `longhorn-flash` | 2 | daily + weekly | Canonical explicit flash tier. `longhorn-fast` is a compatibility alias. |
| Single-pod, no app-layer HA | One pod owns the state and would fail hard on a single-replica fault | `longhorn-redundant` | 2 | daily + weekly | Flash-pinned singleton config or SQLite state such as Grafana, Jellyfin config, or Plex config. |
| Catch-all | The app has no capacity/archive requirement | `longhorn` | 2 | daily + weekly | Default flash-backed choice. Select tank explicitly; it is not an automatic spillover tier. |
| Media on the GPU worker | The PVC must follow media/transcoding workloads onto `media-storage` nodes | `longhorn-media` | 3 | daily + weekly | Use only when node placement is the requirement. |
| Pure local static data | The data should stay on a host-local path and not on Longhorn | static PV | n/a | n/a | Example: large model files that should not consume Longhorn replicas. |

The heavy-writer threshold above is intentionally conservative because Atlas's
flash pool is shared across all workers. If the per-drive Grafana panels show a
candidate workload pushing the flash mirror toward sustained saturation, classify
it as `longhorn-tank` even if its absolute IOPS or throughput is lower.

## Class Selection Rules

1. Start with `longhorn` (the flash-backed default). `longhorn-general` is a
   compatibility alias, not a required migration target.
2. Use `longhorn-tank` only when capacity/archive characteristics outweigh
   latency. Tank is explicit and never the default spillover tier. Tank disks
   exist only on Atlas, so both replicas of a tank volume share one physical
   host; keep anything that matters on flash.
3. Use `longhorn-flash` when declaring the physical flash tier explicitly.
   `longhorn-fast` was retired 2026-10-04; its PVCs were relabelled in place.
4. Use `longhorn-redundant` when the workload is a singleton and the app
   cannot self-heal from losing one replica.
5. Use `longhorn-vault-raft` only for Vault raft members. Do not generalize its
   single-replica pattern to other apps without an explicit design review.
6. `longhorn-one-replica-flash` is an explicit,
   opt-in backup-restorable tier. They require documented RPO/RTO, an
   application-specific integrity command, a fresh exact backup, and the
   fail-closed one-PVC migration workflow. They never change existing PVCs.

## Backup Policy

StorageClass recurring jobs and PVC labels are related but not identical:

- StorageClass parameters define the default recurring jobs attached at volume
  creation time.
- PVC labels declare the intended backup cadence in Git and are required even
  when the StorageClass already carries the same daily or weekly jobs.
- If an app intentionally skips backups or skips an expected group, document the
  exception inline and name the bd issue that owns the decision.

Current policy expectations:

- `hourly + daily + weekly` for Vault and heavy continuous writers.
- `daily + weekly` for general app state, redundant singletons, and flash-pinned
  read-mostly data.
- No backup labels only for deliberately excluded PVCs, with the justification
  tracked outside the manifest.

## Restore And Migration Rules

1. A policy correction normally means PVC recreation, not a live patch.
2. Recreate one PVC at a time: backup, scale down, recreate, restore, verify,
   then continue.
3. Treat restored-from-backup volumes carefully. The memos workaround remains an
   exception and should not be used as a general placement precedent.
4. Do not declare a migration wave complete until the storage-policy audit
   script passes for the PVCs in scope.

### Fail-closed PVC cutover targets

`ansible/playbooks/k3s-migrate-longhorn-pvc.yml` retains its N=1 default for
existing callers. Select `migration_target_replicas=2` explicitly for canonical
`longhorn-flash` or `longhorn-tank`; N=1 uses `longhorn-one-replica-{flash,tank}`.
The class defaults from the requested replica count and target pool. An explicit
class override must match that pair; compatibility aliases are not cutover targets.
Changing tiers does not authorize reducing replicas: record the intended count
and approval before running preflight-stop.

Supply the recorded `migration_source_pool`; `migration_target_pool` defaults to
it. Cross-pool moves require `migration_allow_pool_change=true`. Use stable,
distinct target PV and Volume identities, the exact recovery state file, and an
application-specific integrity command. Existing backup, source Retain,
containment, acceptance, and post-cutover backup gates still apply.

Before any destructive step, cutover reads the exact live target StorageClass
and rejects a wrong provisioner, replica count, or disk selector. Its node
selector is applied to the restored Volume and checked on retries, including
when the class has no node selector (an obsolete source selector is not replayed).
Do not clear an enforced target-class node selector manually.

First run the cutover play with `--tags cutover` and
`migration_classify_only=true` plus the intended inputs. This reads the class
and exact source/target identities without mutation. Only proceed to cutover
with the same approved inputs after classification succeeds. This check does
not establish live capacity, physical-host redundancy, or application integrity;
those remain operational preflight and acceptance requirements.

## Known Exceptions

- Prometheus uses `longhorn-flash` despite being a TSDB. On `longhorn-tank`, its
  disk reached 97% I/O busy, write latency reached 852 ms, and a two-hour TSDB
  block write took 41 minutes. This caused repeated rule-query timeouts and
  `PrometheusMissingRuleEvaluations`. Keep its PVC flash-pinned unless later
  measurements prove the tank tier can sustain compaction latency.
- Memos remains governed by its dedicated workaround issue until that issue is
  closed.
- Affine splits storage by workload: `affine-postgres-pvc` remains on flash for
  database latency, while the 50 GiB `affine-storage-pvc` uses
  `longhorn-tank`. The general storage volume holds blobs and other file data;
  pinning three 50 GiB replicas to flash consumed 150 GiB of scheduled flash
  capacity for roughly 1.2 GiB of actual data.
- Some apps are sourced from private manifests outside this repo. When their PVC
  labels cannot be fixed here, track the source-of-truth exception in bd rather
  than encoding private-app details in public docs.

## Related Docs

- [Cluster Operations](cluster-operations.md)
- [Backup And Restore](../recovery/backup-and-restore.md)
- [Longhorn Cross-Pool Resilience Handoff](../archive/handoff/2026-05-29-longhorn-cross-pool-resilience.md)
- [Cross-Pool Migration Complete Handoff](../archive/handoff/2026-05-30-cross-pool-migration-complete.md)
