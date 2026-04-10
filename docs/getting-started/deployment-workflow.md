# Deployment Workflow

Use this document for the current end-to-end flow of provisioning cluster infrastructure, configuring K3s, and deploying platform services or applications.

## Prerequisites

- Proxmox API access and a working cloud-init template
- Terraform, Ansible, `kubectl`, and SSH access
- `~/.ansible_vault_pass`
- Correct values in:
  - `terraform/k3_3node_cluster_<env>/`
  - `ansible/group_vars/`
  - `ansible/inventories/<environment>/hosts.yml`

## Standard Cluster Deployment

### 1. Provision the VMs with Terraform

```bash
cd terraform/k3_3node_cluster_prod
terraform init
terraform plan
terraform apply
```

Use the environment-specific Terraform directory that matches the cluster you are building.

### 2. Deploy K3s and core platform services

```bash
./scripts/deploy-k3s-cluster.sh --prod
./scripts/deploy-k3s-cluster.sh --stage
./scripts/deploy-k3s-cluster.sh --test
```

What the script does:

- loads environment metadata from `scripts/lib/environments.conf`
- validates SSH connectivity to the target nodes
- runs `ansible/playbooks/k3s-deploy-cluster.yml`
- updates local kubeconfig contexts when the deployment succeeds

### 3. Deploy apps or targeted components

Use the app deployment script for the normal environment app set:

```bash
./scripts/deploy-k3s-apps.sh --stage
```

Use component deployment for targeted work:

```bash
./scripts/deploy-component.sh --prod traefik
./scripts/deploy-component.sh --prod vault
./scripts/deploy-component.sh --prod bookstack
./scripts/deploy-component.sh --test all-infra
```

### 4. Verify the cluster

```bash
./scripts/helpers/k3s-context-manager.sh switch prod
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
./scripts/deploy-component.sh --prod traefik --dry-run
```

### Force a redeploy

```bash
./scripts/deploy-component.sh --prod homepage --force
```

### Restore a cluster instead of rebuilding manually

```bash
./scripts/restore-cluster.sh --stage --from prod
```

## Related Docs

- [Repository Overview](repository-overview.md)
- [Cluster Operations](../operations/cluster-operations.md)
- [Backup And Restore](../recovery/backup-and-restore.md)
