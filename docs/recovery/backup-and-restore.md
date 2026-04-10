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

### Restore one app only

```bash
./scripts/restore-cluster.sh --stage --from prod --app bookstack --restore-only
```

## What `restore-cluster.sh` Handles

Depending on flags, the script can:

- rebuild VMs through the environment-specific Terraform directory
- deploy K3s with `./scripts/deploy-k3s-cluster.sh`
- switch cluster context
- run `ansible/playbooks/k3s-restore-from-backup.yml`
- redeploy apps after the restore phase

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

When a new stateful app needs backup/restore support, update `backup_to_pvc_mapping` in `ansible/playbooks/k3s-restore-from-backup.yml`.

Keep both of these values aligned:

- human-readable size such as `500Mi`
- matching byte size such as `536870912`

## Related Docs

- [Longhorn Troubleshooting](longhorn-troubleshooting.md)
- [Production Cutover Checklist](production-cutover-checklist.md)
- [GitOps And ArgoCD](../operations/gitops-and-argocd.md)
