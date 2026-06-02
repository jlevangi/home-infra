# Storage Policy

Use this document to choose a storage class, replica count, and backup cadence
for persistent workloads in the prod cluster. `cluster-operations.md` remains
the runbook; this file is the policy source of truth.

## Class Names

The policy recognizes these intent-based StorageClass names:

| Canonical name | Legacy name | Purpose |
| --- | --- | --- |
| `longhorn` | `longhorn-general` | General-purpose default with soft cross-pool placement |
| `longhorn-fast` | `longhorn-flash` | Low-latency, read-mostly state pinned to flash |
| `longhorn-tank` | `longhorn-steady` | Heavy continuous writers pinned to tank |
| `longhorn-redundant` | `longhorn-singleton` | Single-pod state with no app-layer HA |
| `longhorn-vault-raft` | none | Vault raft members only |
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

## Decision Table

| App class | Use when | StorageClass | Replicas | Backup labels | Notes |
| --- | --- | --- | --- | --- | --- |
| Vault raft member | A pod is already part of an app-level consensus set | `longhorn-vault-raft` | 1 | hourly + daily + weekly | Vault gets HA from raft, not from Longhorn replicas. Keep the PVC single-replica. |
| Heavy continuous writer | The workload is a database, TSDB, or log store, or normal load shows sustained write pressure above about 200 write IOPS or 5 MiB/s at the 95th percentile | `longhorn-tank` | 2 | hourly + daily + weekly | Use for PostgreSQL, MongoDB, Prometheus, and similar steady writers. Loki may skip hourly if log-history loss is acceptable. |
| Read-fast, write-rarely | The workload benefits from low latency but does not append continuously | `longhorn-fast` | 2 | daily + weekly | `memos` still belongs here. This class is not for heavy writers. |
| Single-pod, no app-layer HA | One pod owns the state and would fail hard on a single-replica fault | `longhorn-redundant` | 3 | daily + weekly | Use for singleton config or SQLite-style state such as Grafana, Jellyfin config, or Plex config. |
| Catch-all | The app has no special storage requirement | `longhorn` | 3 | daily + weekly | Default choice. Soft cross-pool placement is the general-purpose path. Keep healthy default-class PVCs where they are unless there is another reason to migrate them. |
| Media on the GPU worker | The PVC must follow media/transcoding workloads onto `media-storage` nodes | `longhorn-media` | 3 | daily + weekly | Use only when node placement is the requirement. |
| Pure local static data | The data should stay on a host-local path and not on Longhorn | static PV | n/a | n/a | Example: large model files that should not consume Longhorn replicas. |

The heavy-writer threshold above is intentionally conservative because Atlas's
flash pool is shared across all workers. If the per-drive Grafana panels show a
candidate workload pushing the flash mirror toward sustained saturation, classify
it as `longhorn-tank` even if its absolute IOPS or throughput is lower.

## Class Selection Rules

1. Start with `longhorn` (the default). `longhorn-general` is an equivalent
   alias, not a required migration target.
2. Move to `longhorn-tank` for any steady writer. Do not put databases, TSDBs,
   or log stores on `longhorn` / `longhorn-general` or `longhorn-fast` just because they are
   small.
3. Move to `longhorn-fast` only for read-mostly, latency-sensitive state where
   the Atlas flash pool has clear headroom.
4. Move to `longhorn-redundant` when the workload is a singleton and the app
   cannot self-heal from losing one replica.
5. Use `longhorn-vault-raft` only for Vault raft members. Do not generalize its
   single-replica pattern to other apps without an explicit design review.

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

## Known Exceptions

- Memos remains governed by its dedicated workaround issue until that issue is
  closed.
- Some apps are sourced from private manifests outside this repo. When their PVC
  labels cannot be fixed here, track the source-of-truth exception in bd rather
  than encoding private-app details in public docs.

## Related Docs

- [Cluster Operations](cluster-operations.md)
- [Backup And Restore](../recovery/backup-and-restore.md)
- [Longhorn Cross-Pool Resilience Handoff](../../handoff/2026-05-29-longhorn-cross-pool-resilience.md)
- [Cross-Pool Migration Complete Handoff](../../handoff/2026-05-30-cross-pool-migration-complete.md)
