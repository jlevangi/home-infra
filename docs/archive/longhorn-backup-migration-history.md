# Historical Note

This document is archived. It preserves migration history and validated restore examples, but the current operator workflow lives in `docs/recovery/backup-and-restore.md`.

# Longhorn Cross-Cluster Backup And Migration Guide

## Overview

This guide documents the current, production-validated workflow for moving stateful applications between clusters with Longhorn. The current pattern is:

1. Deploy manifests from `main` using the environment path under `argocd/apps/<env>`.
2. Freeze ArgoCD only for the root app and workloads involved in the migration.
3. Create Longhorn-native backups from the source cluster.
4. Restore on the target cluster with a Longhorn `Volume` using `fromBackup`.
5. Bind a PV and PVC manually with `volumeName`.
6. Re-enable ArgoCD and hard-refresh the affected apps.

## Environment Layout

- Production cluster: `k3s-prod` (`172.20.20.101-103`)
- Staging cluster: `k3s-stage` (`172.20.20.111-113`)
- Test cluster: `k3s-test` (`172.20.20.121-123`)
- Shared backup location: `nfs://172.20.20.5:/volume1/k3s-storage/longhorn/shared`

## GitOps Model

All clusters now track `main`. Environment separation is path-based:

- prod: `argocd/apps/prod`
- stage: `argocd/apps/stage`
- test: `argocd/apps/test`

Do not use `stage` or `test` as promotion branches. If those branches remain, keep them fast-forwarded to `main`.

## Recommended Migration Process

### Step 1: Freeze ArgoCD And Quiesce The Source App

```bash
kubectl --context k3s-stage patch application root-stage -n argocd --type=json \
  -p='[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
kubectl --context k3s-stage patch application linkding -n argocd --type=json \
  -p='[{"op":"remove","path":"/spec/syncPolicy/automated"}]'

kubectl --context k3s-stage scale deployment linkding -n linkding --replicas=0
kubectl --context k3s-stage get pvc linkding-data-pvc -n linkding
```

Freeze the root app plus each stateful child app involved in the migration. Scale the source deployments down before taking a backup.

### Step 2: Verify The Shared BackupTarget

```bash
kubectl --context k3s-stage get backuptarget default -n longhorn-system -o yaml
kubectl --context k3s-prod get backuptarget default -n longhorn-system -o yaml
```

Expected URL:

```text
nfs://172.20.20.5:/volume1/k3s-storage/longhorn/shared
```

If the target URL is empty, patch it before creating backups:

```bash
kubectl --context k3s-stage patch backuptarget default -n longhorn-system --type=merge \
  -p '{"spec":{"backupTargetURL":"nfs://172.20.20.5:/volume1/k3s-storage/longhorn/shared"}}'
```

### Step 3: Create Longhorn Snapshot And Backup Objects

Find the Longhorn volume backing the PVC:

```bash
kubectl --context k3s-stage get pvc linkding-data-pvc -n linkding \
  -o jsonpath='{.spec.volumeName}{"\n"}'
```

Create the snapshot and backup resources, then wait until the backup completes. The resulting backup URL format is:

```text
nfs://172.20.20.5:/volume1/k3s-storage/longhorn/shared?backup=<backup-name>&volume=<volume-name>
```

### Step 4: Freeze The Target App And Replace The PVC

```bash
kubectl --context k3s-prod patch application root-prod -n argocd --type=json \
  -p='[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
kubectl --context k3s-prod patch application linkding -n argocd --type=json \
  -p='[{"op":"remove","path":"/spec/syncPolicy/automated"}]'

kubectl --context k3s-prod scale deployment linkding -n linkding --replicas=0
kubectl --context k3s-prod delete pvc linkding-data-pvc -n linkding
```

Only delete the target PVC when you are explicitly replacing it with a restored Longhorn volume.

### Step 5: Restore A Longhorn Volume From Backup

Create the Longhorn `Volume` with `fromBackup`:

```yaml
apiVersion: longhorn.io/v1beta2
kind: Volume
metadata:
  name: linkding-data-restored
  namespace: longhorn-system
spec:
  accessMode: rwo
  backupTargetName: default
  dataEngine: v1
  fromBackup: "nfs://172.20.20.5:/volume1/k3s-storage/longhorn/shared?backup=<backup-name>&volume=<volume-name>"
  numberOfReplicas: 2
  size: "1073741824"
```

Then create a PV and PVC bound to that restored volume:

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: linkding-data-pv
spec:
  accessModes: ["ReadWriteOnce"]
  capacity:
    storage: 1Gi
  csi:
    driver: driver.longhorn.io
    fsType: ext4
    volumeHandle: linkding-data-restored
  persistentVolumeReclaimPolicy: Retain
  storageClassName: longhorn
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: linkding-data-pvc
  namespace: linkding
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 1Gi
  storageClassName: longhorn
  volumeName: linkding-data-pv
```

### Step 6: Re-Enable Workload And ArgoCD

```bash
kubectl --context k3s-prod scale deployment linkding -n linkding --replicas=1

kubectl --context k3s-prod patch application linkding -n argocd --type=merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
kubectl --context k3s-prod patch application root-prod -n argocd --type=merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'

kubectl --context k3s-prod annotate application linkding -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite
```

If ArgoCD reports immutable PVC drift after restore, patch the target overlay so the desired PVC includes the restored `volumeName`.

## Validated Examples

### File-Level Migration

These older file-copy migrations are still valid for tiny config-only or non-Longhorn cases:

- Vaultwarden: prod -> test
- Homepage: prod -> test
- BookStack: NFS -> Longhorn

### Longhorn-Native Migration

This workflow has been validated for:

- linkding: stage -> prod
- ntfy: stage -> prod
- wallos: stage -> prod

## Disaster Recovery Commands

```bash
# Full disaster recovery
./scripts/restore-cluster.sh --prod

# Clone prod data to stage
./scripts/restore-cluster.sh --stage --from prod

# Restore data only
./scripts/restore-cluster.sh --prod --restore-only

# Restore one app only
./scripts/restore-cluster.sh --stage --from prod --app bookstack --restore-only
```

## Shared Backup Configuration

Prod normally owns recurring backups:

```yaml
enable_longhorn_backup: true
longhorn_backup_shared_across_clusters: true
nfs_server_ip: "172.20.20.5"
nfs_share_backup: "/volume1/k3s-storage/longhorn/shared"
```

Stage and test normally run with `enable_longhorn_backup: false`. They can still use the shared target for restores and ad hoc migration backups.

Validate the target directly:

```bash
kubectl get backuptargets -n longhorn-system
kubectl get backupvolumes -n longhorn-system
kubectl get backups -n longhorn-system
```

## Troubleshooting

### Backup target default is not available

Symptoms:
- backup creation is rejected
- `backup target URL is empty`

Fix:

```bash
kubectl get backuptarget default -n longhorn-system -o yaml

kubectl patch backuptarget default -n longhorn-system --type=merge \
  -p '{"spec":{"backupTargetURL":"nfs://172.20.20.5:/volume1/k3s-storage/longhorn/shared"}}'
```

### ArgoCD recreates PVCs during restore

Disable auto-sync before deleting or recreating PVCs:

```bash
kubectl patch application <app-name> -n argocd --type=json \
  -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
```

Re-enable it when the restore is complete:

```bash
kubectl patch application <app-name> -n argocd --type=merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

### ArgoCD stays OutOfSync after PVC restore

Symptoms:
- sync fails on immutable PVC fields
- restored PVC contains `volumeName` that desired state does not include

Fix:
- patch the target overlay so the desired PVC includes the restored `volumeName`
- hard-refresh the affected ArgoCD app

## Migration Checklist

### Pre-Migration
- [ ] Confirm source and target root apps both track `main`
- [ ] Verify the shared backup target on both clusters
- [ ] Disable ArgoCD auto-sync on the root app and affected child apps
- [ ] Ensure adequate storage space on the target cluster
- [ ] Confirm the data to be migrated has been validated on the source cluster

### During Migration
- [ ] Scale down the source workloads cleanly
- [ ] Create Longhorn-native backups for Longhorn-backed apps
- [ ] Record the exact backup URLs used for restore
- [ ] Scale down the target workloads before PVC replacement
- [ ] Verify restored PV/PVC bindings and Longhorn volume health

### Post-Migration
- [ ] Scale workloads back up
- [ ] Re-enable ArgoCD auto-sync on root and child apps
- [ ] Hard-refresh the affected ArgoCD apps
- [ ] Verify application functionality and ingress
- [ ] Document any overlay patches added for restored PVC bindings

## Related Documentation

- [Production Cluster Rebuild Documentation](./LONGHORN-CROSS-CLUSTER-MIGRATION.md)
- [K3s Cluster Management Guide](./CLUSTER_MANAGEMENT.md)
- [Ansible Playbook Documentation](../ansible/README.md)

*Last Updated: April 2026*
