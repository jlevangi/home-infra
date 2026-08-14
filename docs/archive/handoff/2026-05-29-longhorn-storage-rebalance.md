# Longhorn Storage Rebalance & PVC Right-Sizing

**Date:** 2026-05-29
**Status:** In progress — Longhorn settings applied, PVC shrinking not yet started
**Beads issue:** home-infra-2oj

---

## What We Found

### The Problem
Worker-3 was overcommitted at 123% (323GiB scheduled on 245GiB physical disk), causing a cascading issue where:
1. New Longhorn replicas couldn't be created on worker-3 (SIGBUS crash on startup)
2. Worker-3's overcommit prevented healthy replica distribution
3. Memos volume got stuck in a `degraded` state with only 1 healthy replica

### Root Cause Chain
1. **Worker-3 overcommitted**: 323GiB scheduled / 245GiB physical = 123%
2. **All worker VMs share one physical SSD** on Proxmox host `atlas` (`pve/data` thin pool at 94%)
3. **Memos was unique** because it was the only volume that needed a fresh rebuild — all other volumes had existing replicas already allocated
4. **SIGBUS crash** on workers 1 and 3 when creating new replica: the Longhorn engine process dies in ~4ms, before it can serve any data. Only affects the memos-data-v3 volume. Likely a Longhorn v1.11.2 bug with restored-from-backup volumes that have `Dirty: true` metadata.
5. **Longhorn auto-pinned** memos to `nodeSelector: [k3s-prod-worker-2]`, making it impossible to schedule a second replica elsewhere

### The Bigger Picture: Massively Over-Provisioned PVCs
Actual data usage is only ~148GiB per replica, but 368GiB per replica is requested — a 2.5x over-provisioning ratio. With 2 replicas, that's 736GiB scheduled on 735GiB of physical disk. Worker-3 bears the brunt.

---

## What We Already Did (Committed)

### 1. Memos Volume Fix (COMPLETE)
- `memos-data-v3` is now **healthy** with 2 replicas on `k3s-prod-worker-2`
- Volume has `nodeSelector: [k3s-prod-worker-2]`, `replicaSoftAntiAffinity: enabled`, `replicaDiskSoftAntiAffinity: enabled`
- Both replicas on the same disk (`72159d73`), which is fine — worker-2 has 214GiB available
- ArgoCD auto-sync is **re-enabled** for memos
- **Follow-up needed**: Remove nodeSelector once Longhorn SIGBUS bug is resolved (workers 1/3 can host replicas again)

### 2. Longhorn Settings (COMMITTED)
In `ansible/group_vars/k3s_cluster.yml` and applied to the live cluster:

| Setting | Old | New | Effect |
|---------|-----|-----|--------|
| `storage-over-provisioning-percentage` | 150% | **110%** | Prevents new scheduling on disks where scheduled > 110% of physical. Worker-3 is now `Schedulable: False` |
| `replica-auto-balance-disk-pressure-percentage` | 90% | **45%** | Triggers best-effort rebalancing when disk usage exceeds 55% (worker-3 is at 49% used). Only rebalances on volume re-attach, NOT a mass evacuation |
| `replica-auto-balance` | best-effort | best-effort | (unchanged) — rebalances during volume attachment events |

Tasks added to `ansible/roles/cluster_platform/tasks/longhorn-storage-config.yml` to apply these during cluster deploy.

### 3. Current Cluster State
```
Worker-1: 84.9% scheduled, schedulable=True
Worker-2: 97.1% scheduled, schedulable=True  (absorbed refugees from worker-3 eviction attempt)
Worker-3: 102.7% scheduled, schedulable=False (DiskPressure)
```
Worker-3 will gradually shed replicas as pods cycle (redeploys, node reboots) via `best-effort` auto-balance.

---

## What Still Needs To Be Done: PVC Right-Sizing

### The Plan
Shrink 10 PVCs that are 60-98% wasted space. This frees ~104GiB of scheduled space (with 2 replicas), which directly reduces worker-3's pressure.

**Longhorn does NOT support live PVC shrinking.** The workflow for each PVC is:

1. Disable ArgoCD auto-sync for the app
2. Scale down the app (detach the volume)
3. Delete the PVC (and PV + Longhorn volume)
4. Create a new smaller PVC
5. Restore data from Longhorn backup into the new volume (or start fresh if data is trivial)
6. Scale up the app
7. Re-enable ArgoCD auto-sync

### Shrink Targets

| App/Volume | Current | Target | Actual Used | Waste% | Has Backup | Notes |
|---|---|---|---|---|---|---|
| sparkyfitness/postgres | 10Gi | 2Gi | 0.29Gi | 97% | No | PostgreSQL, can reinitialize |
| sparkyfitness/db-backup | 10Gi | 2Gi | 0.22Gi | 98% | No | Backup data, near-empty |
| sparkyfitness/uploads | 10Gi | 2Gi | 0.22Gi | 98% | No | Upload data, near-empty |
| sparkyfitness/server-backup | 5Gi | 1Gi | 0.14Gi | 97% | Yes | Server backup |
| tracearr-data | 10Gi | 2Gi | 0.37Gi | 96% | Yes | In `jellyfin` namespace, managed by `yams` ArgoCD app |
| librechat/mongodb | 8Gi | 4Gi | 1.21Gi | 85% | Yes | Needs backup restore |
| librechat/meilisearch | 5Gi | 2Gi | 0.23Gi | 95% | Yes | Search index, can reindex |
| vault-raft/raft-0 | 5Gi | 2Gi | 0.35Gi | 93% | Yes | HA Vault, 3-node raft |
| vault-raft/raft-1 | 5Gi | 2Gi | 0.00Gi | 100% | Yes | Empty standby |
| vault-raft/raft-2 | 5Gi | 2Gi | 0.35Gi | 93% | Yes | HA Vault, 3-node raft |

**Savings: 52GiB per replica × 2 = 104GiB total scheduled space freed**

### Backup Information
Latest backups (all on NFS `nfs://172.20.20.5:/volume1/k3s-storage/longhorn/shared`):

| Volume | Backup Name | Timestamp |
|--------|-------------|-----------|
| tracearr-data | backup-6a96b344fbd8469e | 2026-05-29T06:07:48Z |
| librechat-mongodb | backup-0e49cc4ac4304609 | 2026-05-29T06:02:16Z |
| librechat-meilisearch | backup-a4a9082872e04645 | 2026-05-29T06:02:11Z |
| data-vault-raft-0 | backup-3cca931210cb4c7e | 2026-05-29T18:00:19Z |
| data-vault-raft-1 | backup-c89dba79d3774a34 | 2026-05-29T15:00:09Z |
| data-vault-raft-2 | backup-410cb4f16f964ec2 | 2026-05-29T18:00:19Z |

Sparkyfitness postgres/uploads/db-backup have **NO backups** (weren't in the recurring job group), but contain <0.3Gi each.

### Restore Workflow (per PVC)

```bash
# The backup URL format is:
# nfs://172.20.20.5:/volume1/k3s-storage/longhorn/shared?backup=<BACKUP_NAME>&volume=<VOLUME_NAME>

# 1. Disable ArgoCD auto-sync for the app
kubectl patch application <APP> -n argocd --type=json -p='[{"op":"remove","path":"/spec/syncPolicy/automated"}]'

# 2. Scale down app (may need to scale multiple deployments if the app has sidecars)
kubectl scale deploy <DEPLOYMENT> -n <NAMESPACE> --replicas=0

# 3. Wait for volume to detach (can take 30-60 seconds)
# Watch: kubectl get volumes -n longhorn-system <VOL> -o jsonpath='{.status.state}'

# 4. Delete PVC and PV
kubectl delete pvc <PVC> -n <NAMESPACE>
kubectl delete pv <PV> --timeout=30s

# 5. Create new smaller PVC (matching storageClass and accessMode)
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: <PVC>
  namespace: <NAMESPACE>
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: <NEW_SIZE>
  storageClassName: <SC>
EOF

# 6. Wait for PVC to bind (creates new empty volume)
# Watch: kubectl get pvc <PVC> -n <NAMESPACE>

# 7. Restore from backup by patching the Longhorn volume
NEW_VOL=$(kubectl get pvc <PVC> -n <NAMESPACE> -o jsonpath='{.spec.volumeName}')
kubectl patch volumes -n longhorn-system "$NEW_VOL" --type=merge \
  -p '{"spec":{"fromBackup":"nfs://172.20.20.5:/volume1/k3s-storage/longhorn/shared?backup=<BACKUP_NAME>&volume=<VOLUME_NAME>"}}'

# 8. Wait for restore to complete and volume to become healthy
# Watch: kubectl get volumes -n longhorn-system "$NEW_VOL"

# 9. Scale up the app
kubectl scale deploy <DEPLOYMENT> -n <NAMESPACE> --replicas=1

# 10. Re-enable ArgoCD auto-sync
kubectl patch application <APP> -n argocd --type=merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

### ArgoCD App Mappings

| App | ArgoCD App | Namespace | Auto-Sync |
|-----|-----------|-----------|-----------|
| tracearr | `yams` | jellyfin | Currently disabled (was disabled for shrink attempt) |
| sparkyfitness | `sparkyfitness` | sparkyfitness | Enabled (Helm chart) |
| librechat | `librechat` | librechat | Needs check |
| vault | `vault` | vault-raft | Needs check |

### Manifest Files That Need Updating

After shrinking PVCs, update the corresponding ArgoCD manifests to match the new sizes:

| App | File | What to change |
|-----|------|---------------|
| sparkyfitness | `argocd/apps/prod/sparkyfitness.yaml` | `postgresql.standalone.persistence.size: 2Gi`, `databaseBackup.persistence.size: 2Gi`, `server.persistence.backup.size: 1Gi`, `server.persistence.uploads.size: 2Gi` |
| tracearr | `argocd/manifests/yams/base/pvc.yaml` | Find the tracearr PVC entry and change `storage: 10Gi` → `storage: 2Gi` |
| librechat | Helm chart (check `argocd/apps/prod/librechat.yaml` for values) | `mongodb.persistence.size`, `meilisearch.persistence.size` |
| vault-raft | ArgoCD vault manifests (check `argocd/manifests/vault-storageclass/base/`) | StatefulSet volume claim template size |

### What NOT to Change
- **librechat/images** (9.3Gi) — keeping at current size, may grow over time
- **paperless** (5Gi each) — keeping as-is per user request
- **All other volumes** — not targeted for this round

---

## Known Issues & Gotchas

1. **ArgoCD self-heal**: ArgoCD with `selfHeal: true` will fight you on scaling down deployments. You MUST disable auto-sync (remove the `automated` block) before scaling down, or the pod gets recreated immediately. This happened during the tracearr attempt — ArgoCD recreated the pod 3 times before we disabled sync.

2. **Memos SIGBUS**: The memos-data-v3 volume still crashes with `signal: bus error (core dumped)` on workers 1 and 3 within ~4ms of replica process creation. This is NOT a disk issue (1GiB dd test passed fine). It's specific to this volume — all other Longhorn volumes work fine on those nodes. Likely a Longhorn v1.11.2 bug. The workaround (nodeSelector pinning to worker-2) is stable.

3. **Worker-2 absorbed refugees**: Worker-2 went from 29 replicas to ~39 during the brief eviction attempt of worker-3. These will gradually rebalance away as pods cycle.

4. **Vault raft shrink**: Shrinking all 3 vault-raft volumes is safe because Vault HA will re-sync from the leader. But do them one at a time and verify Vault is healthy between each.

5. **Sparkyfitness has no backups**: The 3 Sparkyfitness PVCs without backups (postgres, uploads, db-backup) contain <0.3Gi each. The safest approach is to create a backup first, or just recreate empty and let the app reinitialize.

---

## Ground Truth: Current Cluster State

```
Memos volume:       healthy, 2 replicas on worker-2, nodeSelector=[k3s-prod-worker-2]
Worker-1:           48 replicas, 84.9% scheduled, schedulable=True
Worker-2:           57 replicas, 97.1% scheduled, schedulable=True
Worker-3:           40 replicas, 102.7% scheduled, schedulable=False (DiskPressure)

Longhorn settings:
  storage-over-provisioning-percentage: 110%
  replica-auto-balance-disk-pressure-percentage: 45%
  replica-auto-balance: best-effort

ArgoCD yams app: auto-sync CURRENTLY DISABLED (need to re-enable after tracearr shrink)
ArgoCD memos app: auto-sync RE-ENABLED
```

### Committed but NOT yet pushed (already committed+pushed)
- `ansible/group_vars/k3s_cluster.yml` — new Longhorn settings
- `ansible/roles/cluster_platform/tasks/longhorn-storage-config.yml` — tasks to apply them

### NOT yet committed: ArgoCD manifest changes for PVC sizes
- These need to be done as part of the PVC shrinking workflow (update manifests → apply → verify)