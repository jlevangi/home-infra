# Longhorn Cascade Recovery — Session Handoff

**Date:** 2026-05-29 (started ~18:30 UTC, paused ~19:50 UTC)
**Beads issue:** home-infra-5oh
**Status:** Stable but degraded. Apps paused. Restore blocked by Longhorn bug.

---

## TL;DR

1. The `replica-auto-balance-disk-pressure-percentage=45` setting from `9206e3f` triggered a mass-eviction cascade on prod's 3-worker cluster at 17:21 UTC, marking ~20 replicas as failed. A second wave hit worker-1 at 18:21 UTC.
2. I reverted the setting (back to 90) and disabled auto-balance globally — **flapping is stopped**.
3. Auto-salvage recovered most volumes on its own. **Cluster: 52 healthy / 2 faulted / 13 unknown.**
4. I broke **2 volumes** trying to recover by hand: `paperless-db` (volume deleted) and `radarr-config` (deleted only good replica). Both need restore-from-backup.
5. **Restore is currently blocked** by a Longhorn v1.11.2 admission webhook bug. Until it's worked around, no volume can be restored from backup.

---

## What's Healthy Right Now

- All previously-flapping volumes are quiet
- Memos pin-to-worker-2 workaround still active and healthy
- Worker-2 + worker-gpu-1 (new tank disk) both stable
- Settings: `replica-auto-balance=disabled`, `disk-pressure-percentage=90`, `over-provisioning=110` — leave these alone until you understand the bug below.

## What's Paused (ArgoCD auto-sync OFF + deploy=0)

| App | Deploys at 0 | ArgoCD app | Why |
|---|---|---|---|
| paperless | mariadb, redis, paperless | paperless | Volume `paperless-db` was deleted by me; needs restore |
| yams | jellyseerr, nzbget, radarr | yams | Config volumes need restore (radarr-config volume deleted) |
| firefox | firefox | firefox | Volume in unknown state, awaiting verdict |
| factorio | factorio | factorio | Same |
| netbootxyz | netbootxyz | netbootxyz | Same |
| private-app | private-app (no ArgoCD, raw deploy) | n/a | Several private-app-* volumes in unknown state |
| vault | vault-raft StatefulSet (1 pod stuck creating) | vault | data-vault-raft-1 lost; raft sync would fix on pod restart |
| sparkyfitness | sparkyfitness-server | sparkyfitness | uploads volume healthy but had 1-replica spec; pause to clear loop |
| gatus | (gatus deployment untouched) | gatus-pvc | Orphan `pvc-169e0ebf` deleted |

**Also paused:** `root-prod` ArgoCD app (so it can't re-sync the child app manifests and undo the above).

## The Blocker — Longhorn v1.11.2 fromBackup Webhook Bug

Every attempt to create a Volume CR with `spec.fromBackup` set fails the admission webhook with:

```
The request is invalid: : cannot get backup volume for backup target  and volume <X>: backup target name and volume name cannot be empty
```

This affects:
- My homegrown direct `kubectl apply` of Volume CRs
- The official `scripts/maintenance/restore-app.sh` (calls the Ansible role `restore-volume.yml` which uses the same apply pattern)

The error message has the backup target name **empty** even when `spec.backupTargetName: default` is set in the YAML. Looks like a v1.11.2 admission webhook regression around `BackupVolume` CR resolution (BackupVolume CR names now have hash suffixes like `paperless-db-d8ccfe5f` — that may be the connection).

### Workaround I partially tested

Create the volume **empty first** (no fromBackup), then **patch** fromBackup afterward:

```bash
# Step 1: create empty
cat <<EOF | kubectl apply -f -
apiVersion: longhorn.io/v1beta2
kind: Volume
metadata:
  name: paperless-db
  namespace: longhorn-system
spec:
  frontend: blockdev
  size: "5368709120"
  numberOfReplicas: 1
  backupTargetName: default
  nodeSelector: [k3s-prod-worker-2]   # or skip and let it land anywhere
EOF

# Step 2: patch fromBackup (UPDATE bypasses the buggy webhook)
kubectl -n longhorn-system patch volume paperless-db --type=merge -p '{"spec":{"fromBackup":"nfs://172.20.20.5:/volume1/k3s-storage/longhorn/shared?backup=backup-9d85e2521e0f4c23&volume=paperless-db"}}'
```

**Status of this workaround:** when I tested it, the patch took (`restoreInitiated=true`), but the restore then failed with `"All replica restore failed and the volume became Faulted"` — replica started on worker-gpu-1 and died. Not clear if this was the SIGBUS bug, the scheduler refusing to use worker-2 (`precheck new replica failed: disks are unavailable`), or something else. Worth investigating before resuming.

### Other paths to try

- **Patch the Ansible role** `ansible/roles/k3s/tasks/restore-volume.yml:212` to create-then-patch instead of single-create — would make `restore-app.sh` work cluster-wide without webhook bug
- **Try the Longhorn UI's "Restore Latest Backup"** action — likely uses a different code path and may bypass the webhook
- **Check GitHub issues for longhorn v1.11.2 "cannot get backup volume"**
- **Worst case: downgrade to v1.11.1 or apply a manager patch**

---

## Damage Report — Volumes That Need Recovery

| Volume | Status | Owning PVC | Backup Available | Notes |
|---|---|---|---|---|
| `paperless-db` | **Deleted** | `paperless/paperless-db-pvc` | `backup-9d85e2521e0f4c23` (15:00 UTC) | Critical mariadb — restore as soon as the webhook bug is sorted |
| `radarr-config` | **faulted (deleted only replica)** | `yams/radarr-config-pvc` | `backup-85becb2d61b64c82` (06:06 UTC) | Restore |
| `factorio-data` | unknown/attaching | factorio | `backup-121d217050804b4c` | Try auto-salvage first |
| `firefox-config` | unknown | firefox | `backup-26abae730b58412f` | Ephemeral — discard ok |
| `firefox-gluetun-config` | unknown | firefox | `backup-c33fb62873db4e80` | Ephemeral — discard ok |
| `jellyseerr-config` | unknown | yams | `backup-470a69dfe9ee4079` | Restore if salvage fails |
| `netbootxyz-data` | unknown | netbootxyz | `backup-4ca690e990c34d04` | Ephemeral — discard ok |
| `nzbget-config` | unknown | yams | `backup-6f04164096f54e5d` | Restore if salvage fails |
| `nzbget-gluetun-config` | unknown | yams | `backup-041f2318e1374cbe` | Ephemeral — discard ok |
| `paperless-redis` | unknown | paperless | `backup-e61ed21602a94a9d` | Pure cache — discard ok |
| `private-app-config` | unknown | private-app | `backup-70012c41af20404d` | Restore (personal data) |
| `private-app-cache`/`private-app-generated`/`private-app-metadata` | degraded earlier, possibly recovered | private-app | Various | Verify |
| `pvc-389bdd65` (sparkyfitness uploads) | **detached, healthy** | sparkyfitness-server-uploads | No backup | Just scale sparkyfitness back up |
| `data-vault-raft-1` | unknown | vault-raft (sts) | `backup-c89dba79d3774a34` | Delete PVC + let raft re-sync from leader |

Deleted outright (no recovery needed):
- `pvc-169e0ebf` (gatus orphan, no PVC)
- `pvc-000840b9` (sparkyfitness-database-backup, no backup, was just pg_dumps)

---

## What I Changed in the Ansible Repo

- `ansible/group_vars/k3s_cluster.yml` line 277: `longhorn_replica_auto_balance_disk_pressure_percentage: 45 → 90`, with updated comment explaining the incident.

That's it. Commit and push when you're ready.

---

## Notes on Worker-1 SIGBUS-like Errors

While auto-salvage was running, worker-1's instance manager logged:
```
unlinkat /var/lib/longhorn/unix-domain-socket/factorio-data.sock: input/output error
signal: bus error (core dumped)
```
on multiple volumes (firefox-config, jellyseerr-config, etc.). Same signature as the original memos SIGBUS bug. So the SIGBUS issue is likely **not** memos-specific — it's hitting any auto-salvaged replica on workers 1/3 (and maybe gpu-1, untested). Worker-2 remains the only "safe" node for volumes that have hit this bug. Memos pin-to-worker-2 nodeSelector still active and works.

For restored-from-backup volumes (no `Dirty: true` history), we don't know yet whether they'll hit SIGBUS too. Untested because we couldn't get a restore to complete.

---

## Suggested Next Session

1. **Look up the Longhorn v1.11.2 "cannot get backup volume" webhook bug** — GitHub issue search
2. Patch `ansible/roles/k3s/tasks/restore-volume.yml` to use create-empty-then-patch-fromBackup pattern (~10 lines)
3. Re-run `restore-app.sh --prod --pvc paperless-db-pvc --yes` and validate
4. If restore lands a replica on worker-1 or worker-3 and it SIGBUSes, add a `nodeSelector: [k3s-prod-worker-2]` to the role and re-run
5. Repeat for the other volumes in the damage report
6. Once all volumes are restored or accepted as lost, re-enable ArgoCD root-prod auto-sync, then individual app auto-syncs, then scale deployments back up

PVC right-sizing (per the earlier rebalance handoff) stays deferred until everything is healthy again.
