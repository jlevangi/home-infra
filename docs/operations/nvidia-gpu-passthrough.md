# NVIDIA GPU Passthrough on `atlas`

This repo can provision the dedicated GPU worker VM and configure the guest
node for K3s, but the Proxmox host itself still needs a one-time manual
passthrough setup.

## Atlas Host Prep

1. Update `/etc/default/grub`:

```bash
GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt"
```

2. Blacklist host drivers and bind the Quadro P4000 to VFIO:

```bash
cat >/etc/modprobe.d/blacklist-nvidia-p4000.conf <<'EOF'
blacklist nouveau
options vfio-pci ids=10de:1bb1,10de:10f0
EOF
```

3. Ensure VFIO modules load at boot:

```bash
cat >/etc/modules-load.d/vfio.conf <<'EOF'
vfio
vfio_pci
vfio_iommu_type1
vfio_virqfd
EOF
```

4. Rebuild boot artifacts and reboot:

```bash
update-initramfs -u -k all
update-grub
reboot
```

5. Verify the GPU is ready for passthrough after reboot:

```bash
lspci -nnk -s 03:00
```

Expected result: both `03:00.0` and `03:00.1` should be bound to `vfio-pci`.

## Terraform / Cluster Rollout

1. Create or update the dedicated GPU worker from the active Atlas worker stack:
```bash
cd terraform/stacks/k3s/atlas/prod/workers
terraform init
terraform plan
terraform apply
```

The GPU worker is currently sized at 120 GiB (`122880` MiB) RAM in Terraform.
GPU passthrough pins the allocation at VM start, so memory changes require a VM
restart and should be coordinated with host-level memory headroom on `atlas`.

2. Join it to the cluster with the existing deployment workflow:
```bash
./scripts/k3s/deploy-cluster.sh --prod
```

3. Let ArgoCD sync the `nvidia-device-plugin`, `llama-cpp`, `plex`, and
   `jellyfin` apps. `llama-cpp` should stay below the VM memory ceiling; its
   steady-state llama-swap container request/limit is currently 100 GiB.

## Single-Node Maintenance / Memory Resize

For GPU node maintenance, avoid a normal `kubectl drain`: the node holds
Longhorn replicas and draining can trigger avoidable replica churn. Use the
Longhorn-safe helper instead:

```bash
./scripts/maintenance/single-node-longhorn-maintenance.sh --prod --node k3s-prod-worker-gpu-1 --prepare
```

The prepare phase extends Longhorn's replica replenishment wait, disables new
Longhorn replica scheduling on the GPU node without eviction, disables ArgoCD
auto-sync for `root-prod`, `llama-cpp`, `plex`, and `jellyfin`, scales those
workloads to zero, cordons the node, and waits for attached Longhorn volumes to
detach.

After manually power-cycling the VM from Proxmox, restore normal operation:

```bash
./scripts/maintenance/single-node-longhorn-maintenance.sh --prod --node k3s-prod-worker-gpu-1 --restore
```

## Post-Deploy Checks

Run these after ArgoCD finishes syncing:

```bash
kubectl get nodes -L accelerator
kubectl describe node k3s-prod-worker-gpu-1 | grep -A3 nvidia.com/gpu
kubectl -n nvidia-device-plugin get pods
kubectl -n plex get pod -o wide
kubectl -n jellyfin get pod -o wide
```
