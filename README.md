# Home Infrastructure Automation

Infrastructure-as-code for a multi-environment K3s homelab on Proxmox VE. The repository provisions cluster nodes with Terraform, configures them with Ansible, and deploys platform services and applications through ArgoCD.

The repo currently operates three Kubernetes environments:

- `prod` for the primary cluster at `levangie.dev`
- `stage` for production-like validation at `stage.levangie.dev`
- `test` for lower-risk testing at `test.levangie.dev`

## What This Repo Manages

- Proxmox VM provisioning for K3s clusters
- K3s cluster bootstrap and platform components
- Longhorn storage and shared backup/restore workflows
- Traefik ingress, MetalLB, ArgoCD, Vault, and External Secrets Operator
- ArgoCD-managed application manifests under `argocd/`
- Ansible-managed LXC containers under `ansible/lxc_definitions/`

## Quick Start

### Deploy a cluster

```bash
# Provision VMs
cd terraform/k3_3node_cluster_prod
terraform init
terraform plan
terraform apply

# Configure the cluster
cd ../../
./scripts/deploy-k3s-cluster.sh --prod
```

### Deploy infrastructure components

```bash
# Deploy a single infra component (longhorn, metallb, traefik, argocd, vault)
./scripts/deploy-component.sh --prod traefik

# Deploy all core infra in order (fresh cluster bootstrap)
./scripts/deploy-component.sh --prod all-infra
```

Applications are deployed by ArgoCD from `argocd/apps/<env>/` on `main`.

### Manage LXC containers

```bash
./scripts/deploy-lxc.sh --list
./scripts/deploy-lxc.sh nbn-srv
```

## Documentation

Use the docs index as the entry point for everything beyond basic commands:

- [Docs Index](docs/README.md)
- [Repository Overview](docs/getting-started/repository-overview.md)
- [Deployment Workflow](docs/getting-started/deployment-workflow.md)
- [Cluster Operations](docs/operations/cluster-operations.md)
- [GitOps And ArgoCD](docs/operations/gitops-and-argocd.md)
- [Backup And Restore](docs/recovery/backup-and-restore.md)
- [Production Cutover Checklist](docs/recovery/production-cutover-checklist.md)

`docs/SECRETS_RETRIEVAL.md` is intentionally left as a separate personal-only document.

## Repository Layout

```text
ansible/     Configuration, playbooks, roles, inventories, and LXC definitions
argocd/      Root apps, environment app sets, and shared manifests
docs/        Current docs, recovery runbooks, and archived historical notes
scripts/     Operator entry points for deploy, restore, rebuild, and helpers
terraform/   Environment-specific VM provisioning for K3s clusters
```

## Operational Notes

- The current GitOps model is path-based: all clusters reconcile from `main`.
- Environment-specific app enablement lives under `argocd/apps/<env>`.
- Shared manifests live under `argocd/manifests/**`.
- Longhorn backups are shared through NFS so prod data can be restored into stage when needed.
- Most operational workflows assume `~/.ansible_vault_pass` is present.
