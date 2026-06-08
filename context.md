# Longhorn StorageClass Layout

## StorageClasses

| SC Name | Canonical/Legacy | Replicas | diskSelector | antiAffinity | nodeSelector | Purpose | Usage |
|---------|------------------|----------|--------------|--------------|--------------|---------|---------|
| `longhorn` | canonical | 3 | — | `replicaDiskSoftAntiAffinity: enabled` | `general-storage` | General-purpose, cross-pool placement | Most common; prod kube-prometheus, librechat; stage/test gatus, prometheus |
| `longhorn-general` | legacy alias | 3 | — | `replicaDiskSoftAntiAffinity: enabled` | `general-storage` | Alias for `longhorn` | Bound PVCs during migration |
| `longhorn-fast` | canonical | 2 | `diskSelector: flash` | — | — | Flash-pinned, low-latency | memos, pocketid, yams cache |
| `longhorn-flash` | legacy alias | 2 | `diskSelector: flash` | — | — | Alias for `longhorn-fast` | Bound PVCs during migration |
| `longhorn-tank` | canonical | 2 | `diskSelector: tank` | — | — | Tank-pinned, heavy continuous writers | immich db, paperless db, prod sparkyfitness, librechat, prod prometheus |
| `longhorn-steady` | legacy alias | 2 | `diskSelector: tank` | — | — | Alias for `longhorn-tank` | Bound PVCs during migration |
| `longhorn-redundant` | canonical | 3 | — | — | `general-storage` | Higher redundancy for singleton state | grafana-pvc, jellyfin, plex, termix |
| `longhorn-singleton` | legacy alias | 3 | — | — | `general-storage` | Alias for `longhorn-redundant` | Bound PVCs during migration |
| `longhorn-vault-raft` | canonical | 1 | `diskSelector: tank` | — | — | Vault raft voters, single-replica only | prod: ArgoCD overlay; stage: local file |

## PVC Reference Map

### Using `longhorn`

| App/Manifest | PVC(s) |
|--------------|--------|
| `bookstack` | `pvc-app-data.yaml`, `pvc-db-data.yaml` (db is actually `longhorn-tank` — see below) |
| `changedetection` | `pvc.yaml` |
| `factorio` | `pvc.yaml` |
| `firefox` | `pvc.yaml` (2 entries) |
| `gatus-pvc` | `pvc.yaml` |
| `hoarder` | `pvc.yaml` (3 entries) |
| `homepage` | `pvc.yaml` |
| `immich` | `pvc-model-cache.yaml`, `pvc-power-tools.yaml` |
| `linkding` | `pvc.yaml` |
| `microbin` | `pvc.yaml` |
| `netbootxyz` | `pvc.yaml` |
| `notemark` | `pvc.yaml` |
| `ntfy` | `pvc.yaml` |
| `paperless` | `pvc-data.yaml`, `pvc-export.yaml`, `pvc-media.yaml`, `pvc-redis.yaml` |
| `rustdesk` | `pvc.yaml` |
| `snippetbox` | `pvc.yaml` |
| `tasksmd` | `pvc.yaml` |
| `vaultwarden` | `pvc.yaml` |
| `wallos` | `pvc.yaml` |
| `web-poker` | `pvc-mysql.yaml`, `pvc-room.yaml` |
| **Stage/Test** | `gatus.yaml`, `kube-prometheus-stack.yaml` |
| **Prod** | `kube-prometheus-stack.yaml` (1 PVC) |

### Using `longhorn-fast`

| App/Manifest | PVC(s) |
|--------------|--------|
| `memos` | `pvc.yaml` |
| `pocketid` | `pvc.yaml` |
| `yams` | `pvc.yaml` (2 PVCs) |
| **Stage/Test** | `kube-prometheus-stack.yaml` (1 PVC each) |
| **Talos-test** | `kube-prometheus-stack.yaml` (2 PVCs) |

### Using `longhorn-tank`

| App/Manifest | PVC(s) |
|--------------|--------|
| `bookstack` | `pvc-db-data.yaml` (DB) |
| `immich` | `pvc-db.yaml` |
| `paperless` | `pvc-db.yaml` |
| **Prod** | `sparkyfitness.yaml` (3 PVCs), `kube-prometheus-stack.yaml` (1 PVC), `librechat.yaml` (1 PVC) |
| **Stage/Test** | `kube-prometheus-stack.yaml` (1 PVC each) |

### Using `longhorn-redundant`

| App/Manifest | PVC(s) |
|--------------|--------|
| `grafana-pvc` | `pvc.yaml` |
| `jellyfin` | `pvc.yaml` |
| `plex` | `pvc.yaml` |
| `termix` | `pvc.yaml` |

## Environment Overlays

| Environment | SCs Deployed |
|-------------|-------------|
| **Prod** | All base SCs via `kustomization.yaml` → `../../base` |
| **Stage** | `longhorn-vault-raft` (redefined locally, identical to base) |

## Key Observations

1. **Default SC**: `longhorn` is the only default (`storageclass.kubernetes.io/is-default-class: "true"`), so unbound PVCs bind here.

2. **Anti-Affinity semantics**: `replicaDiskSoftAntiAffinity: enabled` soft-preferences replicas across disks with different tags (flash vs tank). With 3 workers having 6 disks total, N=3 volumes typically land 2-tank + 1-flash deterministically on the current topology.

3. **Legacy aliases**: `longhorn-general`, `longhorn-flash`, `longhorn-steady`, `longhorn-singleton` exist to avoid breaking bound PVCs during a full rename. No new manifests should use them.

4. **Vault raft isolation**: `longhorn-vault-raft` intentionally uses `numberOfReplicas: "1"` to prevent Longhorn rebuild storms from impacting Vault's Raft quorum during disk/node maintenance.

5. **Unbound PVCs**: Stage and test `kube-prometheus-stack` applications contain PVCs without explicit `storageClassName` — they will bind to `longhorn` (the default) on those clusters.

## Files of Interest

- `argocd/manifests/longhorn-storage-classes/base/longhorn.yaml` — canonical default SC
- `argocd/manifests/longhorn-storage-classes/base/longhorn-fast.yaml` — flash-pinned
- `argocd/manifests/longhorn-storage-classes/base/longhorn-tank.yaml` — tank-pinned
- `argocd/manifests/longhorn-storage-classes/base/longhorn-redundant.yaml` — high-redundancy singleton
- `argocd/manifests/longhorn-storage-classes/overlays/stage/longhorn-vault-raft.yaml` — stage-only redefinition
- `argocd/manifests/grafana-pvc/base/pvc.yaml` — uses `longhorn-redundant`
- `argocd/manifests/memos/base/pvc.yaml` — uses `longhorn-fast`
- `argocd/manifests/immich/base/pvc-db.yaml` — uses `longhorn-tank`
