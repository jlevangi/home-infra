# Deployment Workflow

Use this document for the current end-to-end flow of provisioning cluster infrastructure, configuring K3s, and deploying platform services or applications.

## Prerequisites

- Proxmox API access and a working cloud-init template
- Terraform, Ansible, `kubectl`, and SSH access
- `~/.ansible_vault_pass`
- Correct values in:
  - `terraform/stacks/k3s/compact-3node/<env>/` or `terraform/stacks/k3s/atlas/<env>/`
  - `ansible/group_vars/`
  - `ansible/inventories/<environment>/hosts.yml`

## Standard Cluster Deployment

### 1. Provision the VMs with Terraform

```bash
cd terraform/stacks/k3s/compact-3node/prod
terraform init
terraform plan
terraform apply
```

Use the environment-specific Terraform stack that matches the cluster shape you are building.

### 2. Deploy K3s and core platform services

```bash
./scripts/k3s/deploy-cluster.sh --prod
./scripts/k3s/deploy-cluster.sh --stage
./scripts/k3s/deploy-cluster.sh --test
```

What the script does:

- loads built-in environment metadata from `scripts/lib/environment-functions.sh`
- validates SSH connectivity to the target nodes
- runs `ansible/playbooks/k3s-deploy-cluster.yml`
- updates local kubeconfig contexts when the deployment succeeds

### 3. Deploy infrastructure components

Applications are deployed by ArgoCD from `argocd/apps/<env>/` on `main`. The
component script handles only core platform pieces (longhorn, metallb, traefik,
argocd, vault):

```bash
./scripts/k3s/deploy-component.sh --test all-infra      # fresh cluster bootstrap
./scripts/k3s/deploy-component.sh --prod traefik        # single component
./scripts/k3s/deploy-component.sh --prod vault
```

### 4. Verify the cluster

```bash
./scripts/k3s/helpers/k3s-context-manager.sh switch prod
kubectl get nodes
kubectl get pods -A
kubectl -n argocd get applications
```

## Environment-Specific Deployment Rules

- Use `prod`, `stage`, and `test` explicitly in script arguments.
- Treat `argocd/apps/<env>` as the environment-level application source of truth.
- Keep shared manifest changes in `argocd/manifests/**`.
- Do not rely on `stage` or `test` Git branches as promotion branches.

## Targeted Operator Workflows

### Dry-run a component deployment

```bash
./scripts/k3s/deploy-component.sh --prod traefik --dry-run
```

### Force a redeploy

```bash
./scripts/k3s/deploy-component.sh --prod homepage --force
```

### Restore a cluster instead of rebuilding manually

```bash
./scripts/maintenance/restore-cluster.sh --stage --from prod
```

## Related Docs

- [Repository Overview](repository-overview.md)
- [Cluster Operations](../operations/cluster-operations.md)
- [Backup And Restore](../recovery/backup-and-restore.md)
