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

## Jottacloud off-site mirror

`jottacloud-backup` runs daily at 03:00 UTC with two Job retries and an
18-hour total deadline across all attempts. `concurrencyPolicy: Forbid`
prevents overlapping scheduled runs; a deadline failure still waits for the
next schedule. Check Job completion and the Healthchecks success ping separately.

The script uses `rclone sync`: unchanged files are skipped, while changed files
are transferred in full (file-level incremental transfer, not block-level delta).
The destination is a rolling mirror, not an independently versioned archive:
`--delete-during` propagates source deletions and `--delete-excluded` removes
excluded destination files. Do not change exclusions or run manual syncs without
reviewing their deletion impact.

NAS mounts are read-only. `k3s-storage` uses the newest matching NAS snapshot;
other roots use live exports. Missing or unreadable roots fail the script, but
that check does not detect an unexpectedly empty or wrong readable export.
Successful sync does not establish restore integrity or recovery of older copies.

## Logical Database Dumps (second layer)

Longhorn backs up blocks. It cannot tell an empty volume from a full one, so
databases also get nightly logical dumps (app `db-backup`, added after the
Outline data loss in `docs/post-mortems/2026-10-02-outline-postgres-ephemeral-pgdata.md`).

- **Opt in:** add the label `backup.levangie.dev/engine: postgres|mariadb|mongodb|surrealdb`
  to the database Deployment/StatefulSet **metadata** labels. Do not put it on the
  pod template: that would restart the database. Helm charts: `commonLabels`.
  SurrealDB has no shell, so the label goes on the app Deployment that holds the
  `SURREAL_*` env (`open-notebook`).
- **Nightly** `db-backup/db-dumps` (02:00 UTC): `kubectl exec` runs the database's
  own dump tool with its in-pod credentials. Output:
  `172.20.20.5:/volume1/k3s-storage/db-dumps/<namespace>/<UTC stamp>.<engine>.gz`.
  Each dump must pass `gzip -t` plus a content check (tables present, completion
  trailer). Workloads scaled to 0 are skipped. Retention: 7 days, plus Sunday
  dumps for 4 weeks, plus 1st-of-month dumps for about 3 months. Jottacloud
  ships `k3s-storage` off-site at 03:00.
- **Weekly** `db-backup/db-restore-test` (Sunday 04:00 UTC): for every labelled
  database, create namespace `restore-test-<ns>`, start a throwaway pod from the
  **source workload's own image** (so versions and extensions match), restore the
  newest dump from the NAS, require the table count (MongoDB: document count,
  0 failed) to match the dump, then delete the namespace. All four engines are
  covered. New databases need no change: the label is enough.
- **Monitoring:** Healthchecks `db-dumps-nightly` and `db-restore-test-weekly`.
  A failed run lists the failing namespaces in the ping body.
- **Excluded:** Plausible ClickHouse (analytics, large).

Restore one database by hand:

```bash
# Postgres (pg_dumpall output; recreates roles + databases)
zcat <dump>.postgres.gz | kubectl -n <ns> exec -i deploy/<db> -- psql -U <user> postgres
# MariaDB
zcat <dump>.mariadb.gz | kubectl -n <ns> exec -i deploy/<db> -- sh -c 'mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD"'
# MongoDB
zcat <dump>.mongodb.gz | kubectl -n <ns> exec -i deploy/<db> -- mongorestore --archive --drop
```

## Quick Commands

### List available backups

```bash
./scripts/maintenance/list-backups.sh
./scripts/maintenance/list-backups.sh --detailed
./scripts/maintenance/list-backups.sh --all
./scripts/maintenance/list-backups.sh --stage
```

### Full disaster recovery

```bash
./scripts/maintenance/restore-cluster.sh --prod
```

### Clone prod data into stage

```bash
./scripts/maintenance/restore-cluster.sh --stage --from prod
```

### Restore data only

```bash
./scripts/maintenance/restore-cluster.sh --prod --restore-only
```

By default, restore discovery now uses Longhorn `BackupVolume` and `Backup`
CR metadata from the cluster API. Force the slower direct NFS backupstore scan
only when that metadata is missing or stale:

```bash
./scripts/maintenance/restore-cluster.sh --prod --restore-only --discovery-mode nfs-scan
```

### Restore one app only

```bash
./scripts/maintenance/restore-app.sh --stage --from prod --app bookstack
./scripts/maintenance/restore-app.sh --prod --pvc factorio-data
./scripts/maintenance/restore-app.sh --prod --app factorio --list
./scripts/maintenance/restore-app.sh --prod --app gatus --backup-before 2026-05-11
./scripts/maintenance/restore-app.sh --prod --app gatus --backup-before 2026-05-11 --list
```

To target an older restore point, use `--backup-before` with an ISO date or
timestamp. The cutoff is exclusive, so `--backup-before 2026-05-11` selects the
newest backup strictly older than `2026-05-11T00:00:00Z` and therefore allows
backups from May 10th or earlier.

If you already know the exact Longhorn backup ID, `--backup-id` restores that
specific snapshot instead of selecting the newest eligible one.

## What `restore-cluster.sh` Handles

Depending on flags, the script can:

- rebuild VMs through the environment-specific Terraform directory
- deploy K3s with `./scripts/k3s/deploy-cluster.sh`
- switch cluster context
- run `ansible/playbooks/k3s-restore-from-backup.yml`
- redeploy apps after the restore phase

## What `restore-app.sh` Handles

Use this when you only want to restore one namespace or one PVC.

- runs `ansible/playbooks/k3s-restore-from-backup.yml` directly
- defaults to Longhorn CR discovery (`longhorn-cr`)
- supports `--list` preview mode before making changes
- supports `--backup-before` for restoring an older backup point in time
- supports `--backup-id` for exact backup selection
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

When selecting an older restore point, pass `restore_backup_before` through the
wrapper script or the Ansible playbook. For example:

```bash
./scripts/maintenance/restore-app.sh --prod --app paperless --backup-before 2026-05-11
```

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
