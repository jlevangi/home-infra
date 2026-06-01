# Longhorn Cross-Pool Storage Architecture

**Date:** 2026-05-29 (~21:00 → 23:55 UTC)
**Beads issues:** home-infra-4w9 (done), home-infra-egr (done), home-infra-28z (done), home-infra-13o (waiting on resilver)
**Status:** Architecture deployed; bulk migration of remaining 46 flash-only volumes pending the failing-SSD resilver.

---

## What This Solves

Today's cascade was the symptom; the root cause is a failing SSD (`TUSQA2488X00041` = atlas `/dev/sdh`, 32 offline uncorrectable sectors, 11+ ZFS deadman events in the last week) in the flash zpool's mirror. Even after the drive swap (already in progress), the entire flash pool sits on cheap UDSS SSDs and stays a single failure domain.

This change spreads each Longhorn volume's replicas across the **flash** pool (cheap-but-fast SSD mirror) and the **tank** pool (4× 3.6 TB WD Red HDD mirror, 14.5 TB total, 13.3 TB free), so a future flash incident leaves data live on tank.

---

## Topology Now Deployed

| Node | Flash disk | Tank disk |
|---|---|---|
| worker-1 | scsi3, 250 GB, `/mnt/longhorn-flash` (existing) | scsi2, 250 GB, `/mnt/longhorn-tank` (NEW) |
| worker-2 | scsi3, 250 GB (existing) | scsi2, 250 GB (NEW) |
| worker-3 | scsi3, 250 GB (existing) | scsi2, 250 GB (NEW) |
| worker-gpu-1 | — | scsi1, 200 GB, `/var/lib/longhorn` (existing) |

Total tank capacity registered in Longhorn: **~935 GB** (worker-1/2/3 ≈ 245 GB each, gpu-1 ≈ 195 GB). Current flash scheduled is ~624 GB, so there's headroom for every volume to have a tank replica.

Disk tags:
- Flash disks: `["general-storage","flash"]`
- Tank disks: `["general-storage","tank"]`

StorageClasses:

| SC | diskSelector | Purpose |
|---|---|---|
| `longhorn` (default) | (nodeSelector=general-storage, no diskSelector) | Default for everything; best-effort cross-pool, audited |
| `longhorn-flash` | `flash` | High-IOPS pin for write-heavy DBs |
| `longhorn-tank` | `tank` | Slow but reliable; cold storage, batch-write |

## The Longhorn Limitation You Accepted

Longhorn has no native "one replica per disk type" primitive when nodes have multiple disks. The anti-affinity settings (`replicaSoftAntiAffinity`, `replicaDiskSoftAntiAffinity`, `replicaZoneSoftAntiAffinity`) can constrain *which* disks Longhorn picks but can't enforce "one of tag=flash, one of tag=tank". So default-SC volumes get best-effort cross-pool placement plus an audit script that flags pairs on the same pool.

## How Cross-Pool Is Enforced / Audited

**Enforcement:** the `longhorn-flash` and `longhorn-tank` SCs use `diskSelector: flash` / `tank` for hard placement. Any PVC that picks one of those SCs has all replicas on that pool, period.

**Audit:** `scripts/maintenance/verify-cross-pool-placement.sh` walks every volume, classifies its replicas by disk-tag pool, skips volumes on the explicit-pin SCs, and flags volumes whose replicas all landed on the same pool. Prints a repair pointer per finding. Run weekly via cron (TODO: add cronjob manifest).

Repair pattern, per misplaced volume:

```bash
# Bump to 3 replicas so Longhorn adds a tank replica
kubectl -n longhorn-system patch volume <VOL> --type=merge -p '{"spec":{"numberOfReplicas":3}}'

# Wait for all 3 replicas healthy
# Then drop back to 2 — Longhorn drops the duplicate flash replica, keeping
# the tank one because zone/disk-anti-affinity preferences favour it.
kubectl -n longhorn-system patch volume <VOL> --type=merge -p '{"spec":{"numberOfReplicas":2}}'
```

When auto-placement keeps both new replicas on flash:

```bash
# Temporarily disable scheduling on all flash disks
for n in k3s-prod-worker-{1,2,3}; do
  kubectl -n longhorn-system patch node.longhorn.io $n --type=json \
    -p='[{"op":"replace","path":"/spec/disks/default-disk-flash/allowScheduling","value":false}]'
done
# Now bump to 3 — only tank disks can accept the new replica
kubectl -n longhorn-system patch volume <VOL> --type=merge -p '{"spec":{"numberOfReplicas":3}}'
# Wait for healthy, then drop back to 2
kubectl -n longhorn-system patch volume <VOL> --type=merge -p '{"spec":{"numberOfReplicas":2}}'
# Re-enable flash scheduling
for n in k3s-prod-worker-{1,2,3}; do
  kubectl -n longhorn-system patch node.longhorn.io $n --type=json \
    -p='[{"op":"replace","path":"/spec/disks/default-disk-flash/allowScheduling","value":true}]'
done
```

## What's Committed (`de9eef4`)

- `ansible/group_vars/k3s_cluster.yml` — `longhorn_tank_disk_path`, `longhorn_flash_storage_class_name`, etc.
- `ansible/inventories/production/host_vars/k3s-prod-worker-{1,2,3}.yml` — `longhorn_tank_disk_device`; fixed stale `longhorn_data_disk_device` references to a scsi1 disk that never existed on these workers
- `ansible/roles/k3s/tasks/longhorn-tank-disk.yml` — new task; modeled on `longhorn-data-disk.yml`. Wired into `main.yml`
- `ansible/roles/cluster_platform/tasks/longhorn-storage-config.yml` — `longhorn-flash` and `longhorn-tank` SC manifests + apply tasks
- `terraform/modules/proxmox-cloudinit-nodes/{main,variables}.tf` — `data_disk_slot` is now configurable (default scsi1; this stack sets scsi2)
- `terraform/stacks/k3s/atlas/prod/workers/main.tf` — enables the 250 GB tank-backed `data_disk` at scsi2. Note: existing VMs got the disk added live via `qm set`; the Proxmox module's `lifecycle.ignore_changes` means Terraform plan is a no-op on existing VMs and the block only takes effect on fresh deploys.
- `scripts/maintenance/verify-cross-pool-placement.sh` — audit script (executable, exits 0/1 for CI use)

## Current Migration State

| Category | Count |
|---|---|
| Cross-pool (1 flash + 1 tank) | 20 |
| Flash-only | 46 |
| Tank-only | 2 (gpu-1 holdovers) |

The 14 volumes I had set to `numReplicas=1` during the recovery were bumped back to 2 just now — about 13 of them landed cross-pool organically because tank has much more room than flash. The 46 still-flash-only volumes are pre-existing 2-replica volumes that were placed before the tank disks existed.

## Still TODO (after resilver finishes)

1. **Migrate the 46 flash-only volumes to cross-pool** — beads `home-infra-?` (created above). Use the repair runbook. Do NOT do this until the failing-flash-drive resilver completes: rebuilds read from the existing flash replica, and reads of bad LBAs on `/dev/sdh` trigger SIGBUS in the engine process.
2. **Re-attempt the failed restores** (paperless-db, one private config PVC, radarr-config, jellyseerr-config, factorio-data, etc.) — beads `home-infra-13o`. The "v1.11.2 fromBackup webhook bug" was likely the failing drive in disguise — the webhook calls into the backupstore client which reads from the flash side. After the drive swap, retry.
3. **Move write-heavy DB PVCs to `longhorn-flash` SC** — paperless-db, immich-db, librechat-mongodb, kioto-postgres-data, data-vault-raft-{0,1,2}. StorageClass on a PVC is immutable, so each is delete-then-restore-from-backup.
4. **Add a cronjob manifest for the audit script** so misplacement is detected weekly. Emit a Prometheus metric.
5. **Cleanup**: re-enable `replica-auto-balance` to `best-effort` once everything is stable (it's currently `disabled` cluster-side from today's recovery).

## Observations Worth Keeping in Mind

- Restarting the worker-3 Longhorn instance manager pod resets accumulated SIGBUS state and helps fresh replicas start. Disrupts ~24 attached volumes briefly.
- `qm set <VMID> -scsi2 tank:250,iothread=1,discard=on,replicate=0,ssd=0` is the per-VM disk add. SCSI bus rescan inside the guest (`echo - - - > /sys/class/scsi_host/host*/scan`) makes the new disk appear without reboot. Stable path is `/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi2`.
