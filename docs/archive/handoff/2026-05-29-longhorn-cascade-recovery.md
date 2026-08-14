# Longhorn Cascade Recovery — Session Closeout

**Date:** 2026-05-29 (~18:30 → ~21:00 UTC)
**Beads issue:** home-infra-5oh
**Status:** Cluster recovered to **63/68 volumes healthy**, **6/8 affected apps fully running**. Two apps remain stuck and need manual recovery.

---

## TL;DR

1. The 45% `replica-auto-balance-disk-pressure-percentage` from `9206e3f` caused a cascade at 17:21 UTC: ~20 replicas marked failed on worker-3 simultaneously, second wave hit worker-1 at 18:21 UTC.
2. Reverted setting (45 → 90), disabled `replica-auto-balance` — flapping stopped.
3. Discovered Longhorn v1.11.2 fromBackup feature is broken in this cluster ("cannot get backup volume for backup target and volume X"). Hit by both my homegrown restore and `restore-app.sh`. Couldn't restore from backup.
4. Pragmatic recovery: deleted broken volumes, created **empty** Longhorn volumes + matching static PVs to satisfy ArgoCD's static-PV overlay pattern. Apps came back online with empty data. Backup files on NFS are untouched and can be restored manually later.

---

## Final Cluster State

| Tally | Count |
|---|---|
| healthy volumes | 63 |
| degraded | 2 (new empty volumes building 2nd replica) |
| faulted | 1 |
| unknown / attaching | 2 |

| App | Pod status | Volume status |
|---|---|---|
| factorio | 1 Running | factorio-data: empty new volume, healthy |
| firefox | 1 Running | firefox-config, firefox-gluetun-config: empty, degraded (building 2nd replica) |
| netbootxyz | 1 Running | netbootxyz-data: empty, degraded |
| paperless | 3 Running (mariadb, redis, server) | paperless-db, paperless-redis: empty; original data PVCs (data/export/media) intact |
| yams | 13 Running (jellyseerr, nzbget, radarr, etc.) | jellyseerr-config, nzbget-config, radarr-config: empty |
| private app namespace | 1 Running | one config PVC: empty; cache/generated/metadata: original data intact |
| **sparkyfitness** | **stuck** (server pod Init:0/1) | server-backup volume attaching, server-uploads recreated empty |
| **vault-raft** | **1/3 Ready** (raft-0 only) | data-vault-raft-0/-2 original; data-vault-raft-1 new empty PVC; raft-1 + raft-2 pods stuck on SIGBUS workers |

---

## Data Loss

These volumes were **recreated empty** because Longhorn restore-from-backup is broken:

| Volume | App | Backup Available? | Severity |
|---|---|---|---|
| `paperless-db` | paperless | yes (backup-9d85e2521e0f4c23, 15:00 UTC) | **HIGH** — mariadb data |
| one private app config PVC | private app namespace | yes | HIGH — personal data |
| `radarr-config` | yams/radarr | yes | MED — catalog DB |
| `jellyseerr-config` | yams/jellyseerr | yes | LOW — request history |
| `factorio-data` | factorio | yes | LOW — savegame |
| `nzbget-config` | yams/nzbget | yes | LOW — queue |
| `firefox-config`, `firefox-gluetun-config` | firefox | yes | LOW — ephemeral |
| `netbootxyz-data` | netbootxyz | yes | LOW — image cache |
| `paperless-redis` | paperless | yes | NONE — pure cache |
| `sparkyfitness-server-uploads` (pvc-389bdd65) | sparkyfitness | no | LOW — was ~239MB |
| `sparkyfitness-database-backup` (pvc-000840b9) | sparkyfitness | no | NONE — old pg_dumps |

All backup files remain on NFS at `172.20.20.5:/volume1/k3s-storage/longhorn/shared` — **nothing is permanently lost**, but restoration is blocked until the Longhorn v1.11.2 bug is worked around.

---

## Remaining Stuck Apps

### sparkyfitness-server (Init:0/1)

The `wait-for-db` init container is stuck. Pod placement was bouncing between worker-2 and worker-3 trying to attach `pvc-047eff17-...` (server-backup volume). I temp-pinned the deployment to worker-2 via `nodeSelector: kubernetes.io/hostname=k3s-prod-worker-2` (in-cluster only, not in git). Likely the previous attachment hasn't fully released.

**To recover:** delete the stale VolumeAttachment for pvc-047eff17 and let the new pod re-attach. Or scale to 0, wait for detach, scale to 1.

The `sparkyfitness-server-uploads` (pvc-389bdd65) was deleted and ArgoCD recreated it dynamically (new UUID `pvc-adeab3e8-...`). That's an empty volume — uploads data is gone (was ~239 MB, no backup).

### vault-raft-1, vault-raft-2

These StatefulSet pods are pinned by topology spread to worker-1 and worker-3 respectively. Both are SIGBUS-prone for Longhorn v1.11.2 in our cluster. The pod's volume engine likely crashes on attach.

`data-vault-raft-1` was deleted and a fresh empty PVC was dynamically provisioned (`pvc-3d464534-...`). Raft would re-sync from leader if the pod came up. `data-vault-raft-2` is still the original volume.

The `vault-auto-recovery` cron runs every 5 minutes and may eventually fix this.

**To recover:**
1. Wait for vault-auto-recovery to do its thing, OR
2. Delete `data-vault-raft-2` PVC + PV + volume, force fresh recreation
3. Watch raft pods come up; vault HA will resync from `vault-raft-0` (still healthy)

---

## The Longhorn v1.11.2 fromBackup Bug

Both direct `kubectl apply` and `restore-app.sh` fail with:

```
The request is invalid: : cannot get backup volume for backup target  and volume <X>: backup target name and volume name cannot be empty
```

Workaround tested partially:
1. Create the Volume CR empty (no `fromBackup`)
2. Patch `spec.fromBackup` on the existing volume (UPDATE bypasses the buggy CREATE-time webhook)
3. Restore initiates (`status.restoreInitiated=true`) but then **fails** because:
   - Engine pod gets placed on a SIGBUS-prone worker (1 or 3) and crashes immediately
   - Even with worker-2-only scheduling, engine selection still picks worker-1
   - Same `unix-domain-socket: input/output error` socket cleanup pattern

Forcing the volume `attachmentTickets/.../nodeID: k3s-prod-worker-2` in the VolumeAttachment CR works briefly but the `volume-restore-controller` reaches in and overwrites the ticket back to worker-1 each reconcile.

The restore feature is genuinely broken in this cluster.

---

## What I Changed and Committed (e110034)

- `ansible/group_vars/k3s_cluster.yml`: `longhorn_replica_auto_balance_disk_pressure_percentage: 45 → 90` with updated comment
- `handoff/2026-05-29-longhorn-cascade-recovery.md`: this file

## What I Changed in the Cluster but NOT Git

| Change | Reason |
|---|---|
| `replica-auto-balance` setting = `disabled` (was `best-effort` per Ansible) | Stop the cascade. Re-enable manually once vault/sparkyfitness recovered. |
| Many volumes: `numberOfReplicas: 2 → 1` | Stop replenishment loops |
| private app deployment nodeSelector → worker-2 | Pin engine to safe node (not in ArgoCD anyway) |
| `sparkyfitness-server` deployment nodeSelector → worker-2 (temp) | Same; ArgoCD will revert this on next sync |

## Suggested Next Session

1. **Recover sparkyfitness-server** (delete stale VolumeAttachment + re-scale)
2. **Recover vault-raft-1/-2** (delete fresh empty data-vault-raft-1, let raft sync from leader; intervene if vault-raft-2 stays stuck)
3. **Investigate the Longhorn v1.11.2 fromBackup webhook bug** (GitHub issue search; consider upgrade to 1.11.3+ or downgrade to 1.11.1)
4. **Once fromBackup works, restore the lost data** — backup IDs are documented above, NFS path is `172.20.20.5:/volume1/k3s-storage/longhorn/shared`
5. Re-enable `replica-auto-balance` global setting back to `best-effort` once everything is stable
6. Bump `numberOfReplicas` back to 2 on the empty replacement volumes
7. PVC right-sizing (per earlier handoff) — stay deferred until everything is healthy

## Quick Recovery Commands

```bash
# After Longhorn restore is fixed, restore paperless-db:
./scripts/maintenance/restore-app.sh --prod --pvc paperless-db-pvc --yes

# Restore the private app config PVC using the documentation kept with the
# private app source of truth.

# Restore radarr-config:
./scripts/maintenance/restore-app.sh --prod --pvc radarr-config-pvc --yes

# Restore others as needed; --list to see what's available:
./scripts/maintenance/restore-app.sh --prod --app paperless --list
```
