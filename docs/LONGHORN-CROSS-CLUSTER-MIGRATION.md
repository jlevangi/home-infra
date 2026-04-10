# Longhorn Cross-Cluster Data Migration Guide

## Overview

This document captures the migration patterns that have been validated in this repository as storage moved from legacy NFS-backed layouts to Longhorn-backed, cross-cluster restores.

## Migration Summary

### Applications Migrated
1. **BookStack** (Production NFS -> Production Longhorn) [validated]
2. **Vaultwarden** (Production NFS -> Test Longhorn) [validated]
3. **Linkding** (Stage Longhorn -> Prod Longhorn) [validated]
4. **ntfy** (Stage Longhorn -> Prod Longhorn) [validated]
5. **Wallos** (Stage Longhorn -> Prod Longhorn) [validated]

### Storage Architecture Transition
- From: NFS hostPath volumes with single-node dependency
- To: Longhorn distributed block storage with multi-node replication
- Backup strategy: shared NFS backup location for cross-cluster restore

## Current GitOps Model

All clusters now track the `main` branch. Environment selection happens by ArgoCD path:

- prod: `argocd/apps/prod`
- stage: `argocd/apps/stage`
- test: `argocd/apps/test`

Do not use `stage` or `test` as promotion branches. If those branches are retained, keep them fast-forwarded to `main`.

## Migration Process

### Phase 1: Longhorn Deployment And Configuration

Key configuration patterns:

```yaml
longhorn_replica_count: "{{ [groups[worker_group] | length, 3] | min }}"
longhorn_backup_shared_across_clusters: true
nfs_backup_target: "nfs://172.20.20.5:/volume1/k3s-storage/longhorn/shared"
```

Critical fixes that matter during restore:

1. Use `nfs://HOST:/absolute/path` for the shared backup target.
2. Recreate the Longhorn StorageClass when replica defaults must change.
3. Use the Longhorn `BackupTarget` CRD directly rather than assuming a Helm-only setting will reconcile it.

### Phase 2: Legacy File-Level Migrations

These were validated before the current Longhorn-native restore pattern:

- BookStack NFS -> Longhorn using migration pods
- Vaultwarden prod -> test using tar archives and restore pods

These are still acceptable for tiny config-only moves or non-Longhorn legacy data.

### Phase 3: Longhorn-Native Stage -> Prod Restores

This is now the preferred migration path for Longhorn-backed applications.

Validated applications:
- `linkding`
- `ntfy`
- `wallos`

Validated pattern:
1. Keep ArgoCD source-of-truth on `main`.
2. Freeze `root-stage` and the source child apps.
3. Scale down the source workloads.
4. Create Longhorn-native snapshots and backups on stage.
5. Freeze `root-prod` and the target child apps.
6. Scale down the target workloads and remove the PVCs being replaced.
7. Restore to prod with a Longhorn `Volume` using `fromBackup`.
8. Create manual PV/PVC bindings with `volumeName`.
9. Patch prod overlays if ArgoCD would otherwise fight the restored PVC.
10. Re-enable auto-sync and hard-refresh the affected apps.

## Shared Backup Configuration

```yaml
backup_target_url: "nfs://172.20.20.5:/volume1/k3s-storage/longhorn/shared"
```

Operational notes:
- Prod normally owns recurring Longhorn backups.
- Stage and test normally keep recurring backups disabled.
- Stage and test can still use the shared target for restores and ad hoc migration backups.

## Key Lessons Learned

### Configuration Requirements
1. The shared target URL must be present on every cluster that will create or restore backups.
2. `fromBackup` on the Longhorn `Volume` is the reliable restore path.
3. PV/PVC rebinding must use the restored Longhorn volume name explicitly.

### Migration Best Practices
1. Always backup before migration and record the exact backup URL used.
2. Use Longhorn-native restore when both source and target already use Longhorn.
3. Use migration pods only for file-level or legacy storage moves.
4. Freeze ArgoCD before PVC replacement so self-heal does not race the restore.
5. Patch desired PVC state if needed because restored `volumeName` bindings are immutable.
6. Verify volume health and application behavior before closing the migration window.

### Cross-Cluster Considerations
1. Shared backup location enables backup and restore between clusters.
2. All nodes must have working access to the NFS backup target.
3. DNS-related hook jobs may require namespace-local secrets after a restore.

## Next Steps

1. Keep the shared BackupTarget healthy on all clusters.
2. Continue validating disaster recovery using cross-cluster restores.
3. Prefer prod recurrence plus stage/test ad hoc migration backups to limit storage use.
4. Keep docs and overlays aligned whenever restored PVC bindings are introduced.

## Verification Commands

```bash
# Check Longhorn volume health
kubectl get volumes -n longhorn-system

# Check PVC bindings
kubectl get pvc -A

# Check ArgoCD health
kubectl -n argocd get applications
```

*Updated April 2026*
