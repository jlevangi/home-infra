# Repository Overview

This repository manages a Proxmox-backed K3s homelab with Terraform, Ansible, Longhorn, Traefik, MetalLB, ArgoCD, Vault, and application manifests under GitOps.

## Environments

The repo currently maintains three Kubernetes environments:

| Environment | Purpose | Node Range | Domain |
| --- | --- | --- | --- |
| `prod` | Primary production cluster | `172.20.20.101-103` | `levangie.dev` |
| `stage` | Production-like validation | `172.20.21.111-113` | `stage.levangie.dev` |
| `test` | Lower-risk testing | `172.20.21.121-123` | `test.levangie.dev` |

Environment metadata used by the deployment scripts lives in `scripts/lib/environment-functions.sh`.

## Current Source Of Truth

### Infrastructure provisioning

- Terraform under `terraform/stacks/**` provisions the active VM layer.
- Legacy Terraform roots that predate the `modules/` + `stacks/` layout live under `terraform/archive/`.
- Ansible under `ansible/` configures the cluster, installs platform services, and runs maintenance.

### GitOps

- All clusters reconcile from the `main` branch.
- Environment separation is path-based, not branch-based.
- Environment app sets live under `argocd/apps/prod`, `argocd/apps/stage`, and `argocd/apps/test`.
- Shared manifests live under `argocd/manifests/**`.
- Root ArgoCD apps live under `argocd/root-apps/`.

### Applications

The repo currently includes platform and application manifests such as:

- `bookstack`
- `vaultwarden`
- `pocketid`
- `plex`
- `gatus`
- `linkding`
- `microbin`
- `ntfy`
- `paperless`
- `wallos`

Not every app is enabled in every environment. The environment-specific app directories are the authoritative source for what each cluster reconciles.

## Key Repository Areas

```text
ansible/group_vars/        Shared and environment-specific config
ansible/inventories/       Environment inventories for production, staging, test, and lxc
ansible/playbooks/         Cluster, app, component, restore, maintenance, and lxc playbooks
ansible/lxc_definitions/   Declarative LXC container and template definitions
argocd/apps/               Environment app sets
argocd/manifests/          Shared app manifests and overlays
scripts/                   Operator entry points
terraform/                 VM provisioning per environment
```

## Operator Assumptions

- `~/.ansible_vault_pass` exists for automated runs.
- You use the scripts in `scripts/` instead of calling ad hoc commands first.
- Production changes should usually be validated in `stage` or `test` before they reach `prod`.

## Related Docs

- [Deployment Workflow](deployment-workflow.md)
- [Cluster Operations](../operations/cluster-operations.md)
- [GitOps And ArgoCD](../operations/gitops-and-argocd.md)
