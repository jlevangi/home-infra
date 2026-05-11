# Backup And Restore

Use this document for the current Longhorn backup model, disaster recovery entry points, and the validated manual restore pattern for stateful applications.

## Current Backup Model

Longhorn backups are shared across clusters through NFS:

```text
nfs://172.20.20.5:/volume1/k3s-storage/longhorn/shared
```

### Expected environment behavior

| Environment | Recurring Backups | Typical Restore Source |
| --- | --- | --- |
| `prod` | enabled | its own backups |
| `stage` | disabled | `prod` |
| `test` | disabled | ad hoc or none |

The intended configuration pattern is:

- `prod`: `enable_longhorn_backup: true`
- `stage`: `enable_longhorn_backup: false`
- `test`: `enable_longhorn_backup: false`

## Quick Commands

### List available backups

```bash
./scripts/helpers/list-backups.sh
./scripts/helpers/list-backups.sh --detailed
./scripts/helpers/list-backups.sh --all
./scripts/helpers/list-backups.sh --stage
```

### Full disaster recovery

```bash
./scripts/restore-cluster.sh --prod
```

### Clone prod data into stage

```bash
./scripts/restore-cluster.sh --stage --from prod
```

### Restore data only

```bash
./scripts/restore-cluster.sh --prod --restore-only
```

By default, restore discovery now uses Longhorn `BackupVolume` and `Backup`
CR metadata from the cluster API. Force the slower direct NFS backupstore scan
only when that metadata is missing or stale:

```bash
./scripts/restore-cluster.sh --prod --restore-only --discovery-mode nfs-scan
```

### Restore one app only

```bash
./scripts/restore-app.sh --stage --from prod --app bookstack
./scripts/restore-app.sh --prod --pvc factorio-data
./scripts/restore-app.sh --prod --app factorio --list
```

## What `restore-cluster.sh` Handles

Depending on flags, the script can:

- rebuild VMs through the environment-specific Terraform directory
- deploy K3s with `./scripts/deploy-k3s-cluster.sh`
- switch cluster context
- run `ansible/playbooks/k3s-restore-from-backup.yml`
- redeploy apps after the restore phase

## What `restore-app.sh` Handles

Use this when you only want to restore one namespace or one PVC.

- runs `ansible/playbooks/k3s-restore-from-backup.yml` directly
- defaults to Longhorn CR discovery (`longhorn-cr`)
- supports `--list` preview mode before making changes
- avoids the broader VM rebuild and cluster-verification flow in `restore-cluster.sh`

## Manual Longhorn Restore Pattern

Use this when replacing an app PVC with a restored Longhorn volume.

### 1. Freeze ArgoCD before touching PVCs

```bash
kubectl --context k3s-prod patch application root-prod -n argocd --type=json \
  -p='[{"op":"remove","path":"/spec/syncPolicy/automated"}]'

kubectl --context k3s-prod patch application <app-name> -n argocd --type=json \
  -p='[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
```

### 2. Scale down the workload and identify the source backup

```bash
kubectl --context k3s-prod scale deployment <app-name> -n <namespace> --replicas=0
kubectl --context k3s-stage get pvc <pvc-name> -n <namespace> \
  -o jsonpath='{.spec.volumeName}{"\n"}'
```

### 3. Restore using a Longhorn `Volume`

Use a Longhorn `Volume` with `fromBackup`. Do not use a PVC `dataSource` with `kind: Backup`.

```yaml
apiVersion: longhorn.io/v1beta2
kind: Volume
metadata:
  name: app-data-restored
  namespace: longhorn-system
spec:
  accessMode: rwo
  backupTargetName: default
  dataEngine: v1
  fromBackup: "nfs://172.20.20.5:/volume1/k3s-storage/longhorn/shared?backup=<backup-name>&volume=<volume-name>"
  numberOfReplicas: 2
  size: "1073741824"
```

### 4. Bind the restored volume with a PV and PVC

The PV must point its CSI `volumeHandle` at the restored Longhorn volume, and the PVC must bind via `volumeName`.

### 5. Re-enable ArgoCD and hard-refresh the app

```bash
kubectl --context k3s-prod patch application <app-name> -n argocd --type=merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'

kubectl --context k3s-prod annotate application <app-name> -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite
```

If ArgoCD reports immutable PVC drift after the restore, patch the target overlay so the desired PVC includes the restored `volumeName`.

## Shared Backup Target Validation

```bash
kubectl -n longhorn-system get backuptarget default -o yaml
kubectl -n longhorn-system get backupvolumes
kubectl -n longhorn-system get backups
```

Expected URL:

```text
nfs://172.20.20.5:/volume1/k3s-storage/longhorn/shared
```

If the target is empty:

```bash
kubectl patch backuptarget default -n longhorn-system --type=merge \
  -p '{"spec":{"backupTargetURL":"nfs://172.20.20.5:/volume1/k3s-storage/longhorn/shared"}}'
```

## Adding A New Restorable App

No static restore mapping is required anymore.

As long as the app stores data on a Longhorn PVC and Longhorn backups exist for
that PVC, the restore playbook will discover it automatically from Longhorn
metadata. The NFS scan fallback uses the same PVC labels embedded in the
backupstore.

If a new app does not appear in restore discovery, check these first:

- the PVC is backed by Longhorn
- the backup objects include `KubernetesStatus` with the expected namespace and PVC name
- the backup target is healthy and `kubectl -n longhorn-system get backupvolumes,backups` shows the volume

## Backup Cleanup

Use the maintenance helper to list or delete Longhorn backups through the API
without scanning NFS:

```bash
./scripts/maintenance/prune-longhorn-backups.sh --context k3s-prod --namespace factorio --pvc factorio-data
./scripts/maintenance/prune-longhorn-backups.sh --context k3s-prod --backup-id backup-04931f82cedd445f --delete
```

## Related Docs

- [Longhorn Troubleshooting](longhorn-troubleshooting.md)
- [Production Cutover Checklist](production-cutover-checklist.md)
- [GitOps And ArgoCD](../operations/gitops-and-argocd.md)
