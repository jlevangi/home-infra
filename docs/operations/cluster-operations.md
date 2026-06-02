# Cluster Operations

Use this runbook for normal day-2 Kubernetes operations: switching context, deploying components, validating platform health, and running the most common direct commands.

## Environment Summary

| Environment | Context | Inventory | Domain |
| --- | --- | --- | --- |
| `prod` | `k3s-prod` | `ansible/inventories/production/hosts.yml` | `levangie.dev` |
| `stage` | `k3s-stage` | `ansible/inventories/staging/hosts.yml` | `stage.levangie.dev` |
| `test` | `k3s-test` | `ansible/inventories/test/hosts.yml` | `test.levangie.dev` |

## Context Management

### Set up or refresh kubeconfig contexts

```bash
./scripts/k3s/helpers/k3s-context-manager.sh setup
```

### Switch clusters

```bash
./scripts/k3s/helpers/k3s-context-manager.sh switch prod
./scripts/k3s/helpers/k3s-context-manager.sh switch stage
./scripts/k3s/helpers/k3s-context-manager.sh switch test
```

### Inspect available contexts

```bash
./scripts/k3s/helpers/k3s-context-manager.sh list
./scripts/k3s/helpers/k3s-context-manager.sh status
```

If you use the shell helpers, source `scripts/k3s/helpers/k3s-shell-functions.sh` from your shell profile.

## Component Deployment

### Common commands

```bash
./scripts/k3s/deploy-component.sh --list
./scripts/k3s/deploy-component.sh --prod traefik
./scripts/k3s/deploy-component.sh --prod metallb
./scripts/k3s/deploy-component.sh --prod longhorn
./scripts/k3s/deploy-component.sh --prod argocd
./scripts/k3s/deploy-component.sh --prod vault
./scripts/k3s/deploy-component.sh --prod bookstack
./scripts/k3s/deploy-component.sh --prod homepage --force
```

### Current infrastructure component order

`deploy-component.sh` treats these as the infrastructure stack:

1. `longhorn`
2. `metallb`
3. `traefik`
4. `argocd`
5. `vault`

Use `all-infra` for a fresh cluster when you want to apply them in order.

## Cluster Maintenance

### Graceful shutdown and power-on

```bash
./scripts/maintenance/shutdown-k3s-cluster.sh --stage
./scripts/maintenance/power-on-k3s-cluster.sh --stage
```

`power-on-k3s-cluster.sh` powers on the Proxmox VMs for the selected environment, waits for them to be running, and then invokes the normal restart flow.

### Service restart when VMs are already up

```bash
./scripts/maintenance/restart-k3s-cluster.sh --stage
```

## Direct Ansible Commands

Use the wrapper scripts first. Drop to Ansible directly when you need tighter control.

### Deploy one infrastructure component

```bash
ansible-playbook -i ansible/inventories/production/hosts.yml \
  ansible/playbooks/k3s-deploy-component.yml \
  -e deploy_component=traefik \
  -e target_cluster=k3s_cluster_prod \
  --vault-password-file ~/.ansible_vault_pass
```

### Deploy one app

Applications are deployed by ArgoCD, not Ansible. Edit the relevant manifest under
`argocd/apps/<env>/` or `argocd/manifests/**` and let ArgoCD reconcile from `main`.
To force a sync immediately:

```bash
kubectl -n argocd patch application <app-name> --type=merge \
  -p '{"operation":{"sync":{}}}'
```

## Health Checks

### Cluster baseline

```bash
kubectl get nodes
kubectl get pods -A
kubectl get pvc -A
kubectl -n argocd get applications
```

### Traefik

```bash
kubectl -n traefik-system get pods
kubectl -n traefik-system get svc traefik
kubectl -n traefik-system get ingressroute
```

### MetalLB

```bash
kubectl -n metallb-system get pods
kubectl -n metallb-system get ipaddresspool
kubectl -n metallb-system get l2advertisement
kubectl get svc -A | grep LoadBalancer
```

### Longhorn

```bash
kubectl -n longhorn-system get pods
kubectl -n longhorn-system get backuptarget
kubectl -n longhorn-system get volumes.longhorn.io
kubectl -n longhorn-system get replicas.longhorn.io
```

#### Cross-pool storage model (prod)

Each Atlas worker has a flash tier (`/mnt/longhorn-flash`) and a tank tier
(`/mnt/longhorn-tank`); `worker-gpu-1` has tank only. Disks are tagged `flash`
or `tank`. `longhorn` remains the normal general-purpose default.
`longhorn-general` is an equivalent alias for the same 3-replica soft
cross-pool model; healthy PVCs do not need to migrate between the two names
just for cosmetic consistency.

Use `docs/operations/storage-policy.md` for the class-selection rules, backup
cadence, naming transition, and exceptions. This runbook keeps only the
operator-facing summary:

| Canonical SC | Current alias | Replicas | Pinning | Operational summary |
|---|---|---|---|---|
| `longhorn` | `longhorn-general` | 3 | nodeSelector=general-storage, soft cross-pool | General-purpose default; `longhorn-general` is only an alias |
| `longhorn-redundant` | `longhorn-singleton` | 3 | nodeSelector=general-storage | Singleton state with no app-layer HA |
| `longhorn-fast` | `longhorn-flash` | 2 | diskSelector=flash | Latency-sensitive, low-write PVCs |
| `longhorn-tank` | `longhorn-steady` | 2 | diskSelector=tank | Heavy continuous writers |
| `longhorn-vault-raft` | none | 1 | none | Vault raft only |
| `longhorn-media` | none | 3 | nodeSelector=media-storage | Media workloads that must follow the GPU worker |

Pinned classes are intentional tradeoffs. If a steady-state volume only behaves
correctly after a runtime `kubectl patch` on the Longhorn Volume CR, treat that
as policy drift and move it onto the correct StorageClass via PVC recreation.

#### Verifying cross-pool placement

```bash
scripts/maintenance/verify-cross-pool-placement.sh
```

Walks every volume, classifies its replicas by disk-tag pool, and flags any
volume whose replicas all landed on the same pool (skipping the intentionally
pinned fast/steady classes and any legacy aliases still using those names). Exit code 0 means no
misplacements. Run on demand after Longhorn maintenance and at least monthly
as drift detection.

Known expected exception: `memos-data-v3` is pinned to one worker with both
replicas on the same disk per the memos workaround issue and will always
flag; that's not a regression.

#### Migrating a misplaced volume

If the audit flags a volume, repair via:

```bash
# Dry-run first to see what would happen
scripts/maintenance/migrate-volumes-to-cross-pool.sh --dry-run

# For volumes whose replicas are all on tank, force the new replica to flash
scripts/maintenance/migrate-volumes-to-cross-pool.sh --force-flash --keep-extra <volume>

# Opposite case
scripts/maintenance/migrate-volumes-to-cross-pool.sh --force-tank --keep-extra <volume>
```

`--keep-extra` leaves the volume at `numberOfReplicas=3` to match the default
SC's new shape. Without it the script ends at N=2 cross-pool (older behavior).

The script disables scheduling on the over-represented pool cluster-wide while
the bump runs. This has a side effect: any other volume rebuilding a replica
in that window can fail and rebuild on the wrong pool. Migrate one volume at
a time; for large volumes (>50 GB actual size) or volumes mid-rebuild, run in
isolation. See [Longhorn cross-pool resilience handoff](../../handoff/2026-05-29-longhorn-cross-pool-resilience.md)
and the [anti-affinity spike notes](../../handoff/2026-05-30-cross-pool-replica-anti-affinity-spike.md)
for the methodology lessons.

#### Settings reference

These are managed at the Longhorn-system level (not per-SC):

```bash
kubectl -n longhorn-system get setting replica-soft-anti-affinity \
  replica-disk-soft-anti-affinity replica-auto-balance \
  storage-over-provisioning-percentage
```

The StorageClass parameter `replicaDiskSoftAntiAffinity` accepts
`enabled` / `disabled` / `ignored` (not booleans — that's the cluster-level
setting's value form). Using `"true"` produces
`invalid ReplicaDiskSoftAntiAffinity setting: true` from the csi-provisioner
and pending PVCs.

### Proxmox host thin-pool monitoring

`atlas` is managed through the dedicated Proxmox inventory:

```bash
ansible-playbook -i ansible/inventories/proxmox/hosts.yml \
  ansible/playbooks/proxmox-hosts.yml
```

The playbook manages LVM thin-pool autoextend, `prometheus-node-exporter`, and
the LVM textfile metrics collector. Prometheus scrape targets are rendered from
the same inventory:

```bash
ansible-playbook -i ansible/inventories/proxmox/hosts.yml \
  ansible/playbooks/render-proxmox-monitoring.yml
```

Useful checks:

```bash
ansible -i ansible/inventories/proxmox/hosts.yml atlas \
  -m ansible.builtin.command \
  -a 'lvs -a -o vg_name,lv_name,lv_size,data_percent,metadata_percent,seg_monitor /dev/pve/data'

curl -fsS http://172.20.20.6:9100/metrics | grep node_lvm_thin_pool
```

Grafana dashboard: **Proxmox Hosts**.

Critical alert: `ProxmoxThinPoolDataHigh` fires when `pve/data` remains above
85% for 15 minutes.

### ArgoCD and Vault

```bash
kubectl -n argocd get applications
kubectl -n vault-raft get pods
kubectl -n external-secrets get pods
kubectl get clustersecretstore
```

## Common Troubleshooting

- If kubeconfig contexts look stale, rerun `./scripts/k3s/helpers/k3s-context-manager.sh setup`.
- If deployment wrappers fail early, verify `~/.ansible_vault_pass` and SSH connectivity first.
- If PVC-related issues appear after a restore, use the recovery docs before letting ArgoCD self-heal over manual changes.

## Proxmox `pve/data` Thin-Pool Emergency Recovery

`atlas` stores VM OS disks on the `pve/data` LVM thin pool. If this pool reaches
100%, Proxmox can put VMs into `io-error`, K3s nodes can become `NotReady`, and
in-flight migrations or `rsync` jobs can be killed mid-copy.

### 1. Confirm pool pressure

```bash
ssh root@172.20.20.6 \
  'lvs -a -o vg_name,lv_name,lv_size,data_percent,metadata_percent,seg_monitor /dev/pve/data && vgs pve'
```

If `Data%` is near 100, free space immediately or extend the pool before
restarting affected VMs.

### 2. Extend the thin pool when VG space is available

```bash
ssh root@172.20.20.6 'lvextend -L+15G /dev/pve/data'
```

Adjust `+15G` to the actual free VG space shown by `vgs pve`. If the VG has no
free space, add storage or move VM disks off the pool first; autoextend cannot
help without free extents.

### 3. Unstick VMs in `io-error` or prelaunch lock states

Identify affected VMs:

```bash
ssh root@172.20.20.6 'qm list'
```

For each stuck VM:

```bash
ssh root@172.20.20.6 'qm unlock <vmid> || true'
ssh root@172.20.20.6 'qm stop <vmid> --skiplock || true'
ssh root@172.20.20.6 'qm start <vmid>'
```

Known examples from the May 2026 incident:

- `cp-3 = vm-100`
- `worker-3 = vm-105`

### 4. Verify Kubernetes recovery

```bash
./scripts/k3s/helpers/k3s-context-manager.sh switch prod
kubectl get nodes
kubectl get pods -A
kubectl -n longhorn-system get volumes.longhorn.io
```

### 5. Restart interrupted migrations or `rsync` jobs

If a data migration was running when Proxmox entered `io-error`, assume the copy
was interrupted. Restart the migration sidecar/job from the beginning or resume
with checksum validation. For PVC migrations, verify source and destination size
and application readiness before deleting any old volume.

## Large File Placement Policy

Do not place large downloads, models, archives, transcode caches, or temporary
bulk data on VM OS disks backed by `atlas` `pve/data`.

Avoid these locations for large files:

- `~/`
- `/root`
- `/tmp` when it is backed by the root filesystem
- `/var/log`
- application working directories on the OS disk

Use an explicitly provisioned bulk-data location instead:

- Longhorn PVC sized for the workload
- NFS-backed media/download path
- dedicated Proxmox storage pool
- application-specific data volume with monitoring and retention policy

For LLM models or other one-off large downloads, confirm the target path and
backing storage before starting the download. A single large file on a VM OS disk
can exhaust the shared thin pool and impact unrelated cluster nodes.

## Related Docs

- [Storage Policy](storage-policy.md)
- [GitOps And ArgoCD](gitops-and-argocd.md)
- [Backup And Restore](../recovery/backup-and-restore.md)
- [Longhorn Troubleshooting](../recovery/longhorn-troubleshooting.md)
