# Prod K3s Control-Plane VMs

Provisions three dedicated K3s control-plane (server) VMs for the prod cluster, separating etcd + API server from worker workloads. The existing `k3_3node_cluster_prod/` module continues to manage the worker VMs (`k3s-prod-worker-1/2/3`).

## Shape

| VM | IP | Host (default) | vCPU | RAM | Disk |
|----|----|----------------|------|-----|------|
| `k3s-prod-cp-1` | `172.20.20.104` | `pve1` | 4 | 8 GiB | 64 GiB |
| `k3s-prod-cp-2` | `172.20.20.105` | `pve2` | 4 | 8 GiB | 64 GiB |
| `k3s-prod-cp-3` | `172.20.20.106` | `pve3` | 4 | 8 GiB | 64 GiB |

`proxmox_hosts` is a list — set all three entries to the same value if the template hasn't been replicated to every host yet.

## Prerequisites

1. **Replicate `debian12-server-template` to every host listed in `proxmox_hosts`.** Local-only Proxmox storage means cross-node clones either copy over the cluster network (slow, can hit terraform's 30m timeout) or fail. Replicating once up-front keeps `terraform apply` fast and reliable.
2. Copy `terraform.tfvars.example` → `terraform.tfvars` and fill in real values. Do not commit `terraform.tfvars`.

## Apply

```bash
cd terraform/k3_3node_cluster_prod_cp
terraform init
terraform plan
terraform apply
```

After VMs come up, drive K3s installation via the production ansible inventory (CP nodes belong to `k3s_cluster_prod_master`, existing nodes drop to `k3s_cluster_prod_workers`).
