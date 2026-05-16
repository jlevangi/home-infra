# AGENTS.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a **home infrastructure automation repository** that provides infrastructure-as-code for deploying production-ready K3s Kubernetes clusters on Proxmox VE. The repository manages multiple environments (production, test, staging) with automated provisioning and configuration. Applications are deployed via ArgoCD (see `argocd/`), not Ansible.

## Quick Orientation

- **VM lifecycle**: Use Terraform stacks under `terraform/stacks/**` to provision or rebuild cluster nodes on Proxmox VE.
- **Cluster configuration**: Use Ansible for K3s bootstrap, infrastructure components, restores, and LXC container management.
- **Application management**: Treat ArgoCD manifests under `argocd/apps/<env>/` and `argocd/manifests/**` as the source of truth for apps.
- **Secrets**: Store sensitive values in Ansible Vault and keep the vault password in `~/.ansible_vault_pass`.
- **Safer workflow**: Prefer repo scripts in `scripts/` over raw Terraform or Ansible commands because they encode environment-specific behavior.
- **Change discipline**: Test in `--test` or `--stage` first when the risk warrants it, then promote by committing to `main`.

## Architecture

- **Terraform**: VM provisioning on Proxmox VE with cloud-init templates
- **Ansible**: Configuration management, K3s deployment, and LXC container management
- **K3s Kubernetes**: Lightweight Kubernetes distribution
- **Longhorn**: Distributed storage with cross-cluster backup
- **Traefik**: Ingress controller with SSL termination
- **MetalLB**: Load balancer for bare metal Kubernetes
- **NFS Storage**: Backup target and legacy storage integration
- **LXC Containers**: Lightweight containers for standalone services (Docker-capable)

## Key References

- `README.md`: project overview and prerequisites
- `AGENTS.md`: canonical repository workflow and operations reference
- `docs/operations/cluster-operations.md`: cluster management and troubleshooting runbook
- `docs/recovery/backup-and-restore.md`: backup, restore, and disaster recovery procedures

## Common Commands

### Cluster Deployment
```bash
# Deploy production cluster
./scripts/deploy-k3s-cluster.sh --prod

# Deploy test cluster  
./scripts/deploy-k3s-cluster.sh --test

# Deploy staging cluster
./scripts/deploy-k3s-cluster.sh --stage
```

### Application Deployment

Applications are deployed by ArgoCD, not Ansible. To enable, disable, or modify
applications, edit the relevant manifests under `argocd/apps/<env>/` and
`argocd/manifests/**` and let ArgoCD reconcile from `main`.

### Component Deployment
```bash
# Deploy individual infrastructure components (longhorn, metallb, traefik, argocd, vault)
./scripts/deploy-component.sh --prod traefik
./scripts/deploy-component.sh --prod metallb
./scripts/deploy-component.sh --prod longhorn

# Deploy all infra components in order (fresh cluster bootstrap)
./scripts/deploy-component.sh --prod all-infra

# Force redeploy (cleanup and reinstall)
./scripts/deploy-component.sh --prod traefik --force

# Dry run (show commands without executing)
./scripts/deploy-component.sh --prod traefik --dry-run

# List available components
./scripts/deploy-component.sh --list
```

For detailed troubleshooting and manual operations, see [docs/operations/cluster-operations.md](docs/operations/cluster-operations.md) and [docs/recovery/backup-and-restore.md](docs/recovery/backup-and-restore.md).

### Context Management
```bash
# Setup all cluster contexts
./scripts/helpers/k3s-context-manager.sh setup

# Switch between clusters
./scripts/helpers/k3s-context-manager.sh switch prod
./scripts/helpers/k3s-context-manager.sh switch test

# List available contexts
./scripts/helpers/k3s-context-manager.sh list
```

### LXC Container Deployment
```bash
# List available container definitions
./scripts/deploy-lxc.sh --list

# Deploy a specific container
./scripts/deploy-lxc.sh nbn-srv

# Interactive container selection
./scripts/deploy-lxc.sh

# Deploy with verbose output
./scripts/deploy-lxc.sh nbn-srv -v
```

### Terraform Operations
```bash
# Deploy legacy compact 3-node production VMs
cd terraform/stacks/k3s/compact-3node/prod
terraform init
terraform plan
terraform apply

# Deploy Atlas-backed split test VMs
cd terraform/stacks/k3s/atlas/test/workers
terraform init
terraform plan
terraform apply

cd ../control-plane
terraform init && terraform plan && terraform apply
```

### Ansible Operations
```bash
# Run cluster deployment playbook directly
ansible-playbook -i ansible/inventories/production/hosts.yml ansible/playbooks/k3s-deploy-cluster.yml --vault-password-file ~/.ansible_vault_pass
```

### Backup and Restore
```bash
# List available backups
./scripts/helpers/list-backups.sh
./scripts/helpers/list-backups.sh --detailed
./scripts/helpers/list-backups.sh --all

# Full disaster recovery for production
./scripts/restore-cluster.sh --prod

# Clone production data to staging
./scripts/restore-cluster.sh --stage --from prod

# Restore data only (no VM rebuild)
./scripts/restore-cluster.sh --prod --restore-only

# Restore specific app only
./scripts/restore-app.sh --stage --from prod --app bookstack
./scripts/restore-app.sh --prod --pvc factorio-data
```

### Vault Management
```bash
# Edit K3s vault file
ansible-vault edit ansible/group_vars/k3s_cluster_vault.yml

# Edit LXC vault file
ansible-vault edit ansible/group_vars/lxc_vault.yml

# View vault contents
ansible-vault view ansible/group_vars/k3s_cluster_vault.yml
ansible-vault view ansible/group_vars/lxc_vault.yml
```

## Key Directory Structure

```
├── ansible/
│   ├── group_vars/              # Environment-specific variables
│   │   ├── k3s_cluster.yml      # K3s production config
│   │   ├── k3s_cluster_test.yml # K3s test config
│   │   ├── k3s_cluster_stage.yml# K3s staging config
│   │   ├── k3s_cluster_vault.yml# K3s encrypted secrets
│   │   ├── lxc.yml              # LXC shared config
│   │   └── lxc_vault.yml        # LXC encrypted secrets
│   ├── inventories/             # Ansible inventories
│   │   ├── production/
│   │   ├── test/
│   │   ├── staging/
│   │   └── lxc/                 # LXC container inventory
│   ├── lxc_definitions/         # LXC container definitions
│   │   ├── templates/           # LXC template configs (ubuntu-24.04.yml)
│   │   └── containers/          # Container definitions (nbn-srv.yml)
│   ├── playbooks/               # Ansible playbooks
│   │   ├── k3s-deploy-cluster.yml
│   │   ├── k3s-deploy-component.yml     # Single component deployment
│   │   ├── k3s-restore-from-backup.yml  # Longhorn backup restore
│   │   └── lxc-deploy.yml       # LXC deployment playbook
│   └── roles/                   # Ansible roles
│       ├── common/
│       ├── k3s/
│       └── lxc/                 # LXC container role
├── terraform/                   # Infrastructure provisioning (VMs only)
│   ├── modules/                 # Reusable Proxmox VM modules
│   └── stacks/                  # Root Terraform stacks by cluster family/env
│       ├── k3s/
│       └── talos/
├── scripts/                     # Management scripts
│   ├── deploy-k3s-cluster.sh    # K3s cluster deployment
│   ├── deploy-component.sh      # Single infra component deployment
│   ├── deploy-lxc.sh            # LXC container deployment
│   ├── reset-k3s-cluster.sh     # Reset/destroy cluster
│   ├── rebuild-k3s-cluster.sh   # Terraform rebuild cluster
│   ├── restore-cluster.sh       # Disaster recovery script
│   ├── lib/                     # Shared libraries
│   │   ├── environment-functions.sh
│   │   └── environments.conf
│   ├── helpers/                 # Helper utilities
│   │   ├── k3s-context-manager.sh
│   │   └── list-backups.sh
│   └── maintenance/             # Maintenance scripts
│       └── update-k3s-nodes.sh
└── docs/                        # Additional documentation
    └── CLUSTER_MANAGEMENT.md    # Operational runbook
```

## Multi-Environment Architecture

The repository supports three environments:

### Production (`--prod`)
- Cluster nodes: 172.20.20.101-103
- Domain: `levangie.dev` 
- High availability with Longhorn storage
- Production-grade applications

### Test (`--test`)  
- Cluster nodes: 172.20.21.121-125
- Domain: `test.levangie.dev`
- Simplified configuration for testing
- Safe environment for experiments

### Staging (`--stage`)
- Cluster nodes: 172.20.21.111-116  
- Domain: `stage.levangie.dev`
- Production-like testing environment

### Talos Test (experimental)
- Cluster nodes: 172.20.20.131-133
- Distribution: **Talos Linux** + upstream Kubernetes (not K3s, not Debian)
- Managed via `terraform/stacks/talos/test/` (uses the `siderolabs/talos` provider for bootstrap) and `scripts/helpers/import-talos-template.sh` for the Atlas Proxmox template
- VMs have `start_at_node_boot = false` and do not start on Proxmox host boot
- No Ansible: Talos has no SSH/package manager; the existing `k3s` role does not apply here
- App deployment (kubectl/helm, ArgoCD) still works against the cluster API if/when wired up; not yet integrated with `scripts/helpers/k3s-context-manager.sh`

## Application Configuration

Applications are owned by ArgoCD. There is no Ansible app-deploy pipeline.

- App enablement and configuration live under `argocd/apps/<env>/` (per-cluster) and `argocd/manifests/**` (shared).
- Secrets come from Vault via External Secrets Operator (ESO).
- To add or remove an app: commit changes to `argocd/apps/<env>/` on `main` and let ArgoCD reconcile.

### ArgoCD Branching Model

All clusters reconcile from the `main` branch. Environment separation is path-based, not branch-based:

| Environment | Root App | Git Path | Git Branch |
|-------------|----------|----------|------------|
| **Prod** | `root-prod` | `argocd/apps/prod` | `main` |
| **Stage** | `root-stage` | `argocd/apps/stage` | `main` |
| **Test** | `root-test` | `argocd/apps/test` | `main` |

Operational guidance:
- Make environment-specific app enablement changes under `argocd/apps/<env>`
- Make shared manifest changes under `argocd/manifests/**`
- Do not use `stage` or `test` as promotion branches
- If `stage` and `test` branches are retained, keep them fast-forwarded to `main`

## Backup and Restore Strategy

### Backup Configuration

Backups are managed per-environment using Longhorn RecurringJobs:

| Environment | Backups | Restore From | Config Variable |
|-------------|---------|--------------|-----------------|
| **Prod** | Enabled (daily/weekly to NFS) | Own backups | `enable_longhorn_backup: true` |
| **Stage** | Disabled | Prod backups | `enable_longhorn_backup: false` |
| **Test** | Disabled | None (ephemeral) | `enable_longhorn_backup: false` |

All backups are stored on a shared NFS path (`172.20.20.5:/volume1/k3s-storage/longhorn/shared`), enabling cross-cluster restore.

### Backup Storage Structure

Longhorn stores backups in a nested directory structure on NFS:
```
/backupstore/volumes/XX/YY/<volume-name>/
├── volume.cfg          # Volume metadata with KubernetesStatus (namespace, pvcName)
└── backups/
    └── backup_*.cfg    # Individual backup metadata
```

### Restore Process (Technical Details)

The restore process uses Longhorn's native backup restoration. Key technical notes:

1. **Volume Creation**: Use Longhorn Volume CRD with `fromBackup` field (NOT PVC `dataSource` with `kind: Backup`)
2. **PV/PVC Binding**: Must create a PV with CSI `volumeHandle` pointing to the Longhorn volume, then PVC with `volumeName`
3. **Size Format**: Longhorn Volume CRD requires size in bytes (e.g., `536870912`), not human-readable (`500Mi`)
4. **Backup URL Format**: NFS backups use `nfs://` URLs (e.g., `nfs://172.20.20.5:/volume1/k3s-storage/longhorn/shared?backup=backup-xxx&volume=yyy`)

### Restore Commands

```bash
# List available backups
./scripts/helpers/list-backups.sh
./scripts/helpers/list-backups.sh --detailed   # Show individual backup timestamps
./scripts/helpers/list-backups.sh --all        # Show all volume instances

# Full disaster recovery (rebuild VMs + restore data)
./scripts/restore-cluster.sh --prod

# Clone production data to staging
./scripts/restore-cluster.sh --stage --from prod

# Restore data only to existing cluster
./scripts/restore-cluster.sh --prod --restore-only

# Restore specific application
./scripts/restore-app.sh --stage --from prod --app bookstack
./scripts/restore-app.sh --prod --pvc factorio-data

# Using Ansible playbook directly
ansible-playbook -i ansible/inventories/staging/hosts.yml \
  ansible/playbooks/k3s-restore-from-backup.yml \
  -e "restore_action=list" \
  --vault-password-file ~/.ansible_vault_pass

ansible-playbook -i ansible/inventories/staging/hosts.yml \
  ansible/playbooks/k3s-restore-from-backup.yml \
  -e "restore_action=restore target_env=stage app=bookstack" \
  --vault-password-file ~/.ansible_vault_pass
```

### Adding New Applications to Restore Discovery

No static restore mapping is required.

As long as the application stores data on a Longhorn PVC and Longhorn backups
exist for that PVC, `ansible/playbooks/k3s-restore-from-backup.yml` will
discover it automatically from Longhorn metadata. The default path uses
`BackupVolume` and `Backup` CRs, with the slower direct NFS scan retained as a
fallback.

## Vault Password Management

All sensitive data is encrypted using Ansible Vault. The vault password should be stored in `~/.ansible_vault_pass` for automated operations.

Required vault variables are documented in `REQUIRED_VAULT_CREDENTIALS.md`.

## Development Workflow

1. **Infrastructure Changes**: Modify Terraform configurations in environment-specific directories
2. **Configuration Changes**: Update Ansible group_vars files for each environment
3. **Application Changes**: Update ArgoCD manifests under `argocd/apps/<env>` and `argocd/manifests/**`
4. **Secrets Management**: Use `ansible-vault edit` for sensitive data
5. **Validation**: Test in stage or test first, depending on risk and cluster availability
6. **Production**: Promote by committing to `main` and syncing only the intended prod apps

## Important Notes

- Always test changes in the test environment before production deployment
- Use the environment-specific scripts rather than running Ansible directly
- The `k3s-context-manager.sh` script handles kubectl context switching automatically
- Longhorn provides distributed storage with automatic backups to NFS
- All applications use Traefik ingress with automatic SSL via cert-manager
- The vault password file `~/.ansible_vault_pass` is required for all operations

## LXC Container Management

LXC containers are managed via Ansible (no Terraform). Each container is defined in a YAML file.

### Container Definition Structure
Container definitions are stored in `ansible/lxc_definitions/containers/`:

```yaml
container_name: nbn-srv
container_id: 200
description: "Hugo website hosting via Docker"
node: pve1
template: ubuntu-24.04

resources:
  cores: 2
  memory: 2048
  disk_size: 16
  storage: local-lvm

network:
  bridge: vmbr0
  dhcp: true

features:
  unprivileged: true
  nesting: true           # Required for Docker

applications:
  docker_installed: true
```

### Adding a New LXC Container
1. Create a new YAML file in `ansible/lxc_definitions/containers/`
2. Define container settings (ID, resources, features)
3. Run `./scripts/deploy-lxc.sh <container-name>`

### LXC Vault Variables
The `ansible/group_vars/lxc_vault.yml` contains:
- `vault_proxmox_api_host`: Proxmox API endpoint
- `vault_proxmox_api_user`: API user
- `vault_proxmox_api_token_id`: API token ID
- `vault_proxmox_api_token_secret`: API token secret
- `vault_ssh_public_key`: SSH key for container access

## Troubleshooting

### General Issues
- **Context issues**: Run `./scripts/helpers/k3s-context-manager.sh setup` to refresh contexts
- **Vault errors**: Ensure `~/.ansible_vault_pass` contains the correct password
- **Deployment failures**: Check cluster connectivity and vault credentials
- **Storage issues**: Verify NFS server accessibility and Longhorn status

### LXC Issues
- **LXC template missing**: Run `./scripts/deploy-lxc.sh --template-only` to download template
- **LXC container unreachable**: Check Proxmox console for container IP (DHCP assigned)

### Backup/Restore Issues
- **Script won't execute**: Run `dos2unix scripts/helpers/list-backups.sh scripts/restore-cluster.sh` (Windows CRLF issue)
- **Backups not appearing in the fast list view**: Check `kubectl -n longhorn-system get backupvolumes,backups` on the target cluster; `list-backups.sh` now reads Longhorn CR metadata instead of parsing `volume.cfg` over NFS
- **Restore fails with "volume not found"**: Ensure the backup URL uses `nfs://` format, not `s3://`
- **PVC stuck in Pending after restore**: Check that PV was created with correct `volumeHandle` matching the Longhorn volume name
- **Backup creation fails with "backup target default is not available"**: Check `backuptarget/default` in `longhorn-system`; if the URL is empty, patch it to `nfs://172.20.20.5:/volume1/k3s-storage/longhorn/shared`
- **ArgoCD recreates PVC during manual restore**: ArgoCD's self-heal will immediately recreate deleted PVCs, racing against manual PV/PVC creation. Before deleting or recreating any PVC manually, **always disable ArgoCD auto-sync first**:
  ```bash
  # Disable auto-sync (prevents self-heal from recreating objects)
  kubectl patch application <app-name> -n argocd --type=json \
    -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]'

  # ... perform manual PVC/PV operations ...

  # Re-enable auto-sync when done
  kubectl patch application <app-name> -n argocd --type=merge \
    -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
  ```
  Note: `--type=merge -p '{"spec":{"syncPolicy":{"automated":null}}}'` does NOT work to remove the automated block; use the JSON patch `remove` operation instead.
- **ArgoCD reports immutable PVC drift after restore**: Add the restored `spec.volumeName` to the target overlay so desired state matches the live PVC, then hard-refresh the Application
- **Multiple clusters creating backups**: Only prod should have `enable_longhorn_backup: true`; stage/test should have it set to `false` (this auto-deletes RecurringJobs)
