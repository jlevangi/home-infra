# AGENTS.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

1. Think Before Coding
Don't assume. Don't hide confusion. Surface tradeoffs.

Before implementing:

State your assumptions explicitly. If uncertain, ask.
If multiple interpretations exist, present them - don't pick silently.
If a simpler approach exists, say so. Push back when warranted.
If something is unclear, stop. Name what's confusing. Ask.
2. Simplicity First
Minimum code that solves the problem. Nothing speculative.

No features beyond what was asked.
No abstractions for single-use code.
No "flexibility" or "configurability" that wasn't requested.
No error handling for impossible scenarios.
If you write 200 lines and it could be 50, rewrite it.
Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

3. Surgical Changes
Touch only what you must. Clean up only your own mess.

When editing existing code:

Don't "improve" adjacent code, comments, or formatting.
Don't refactor things that aren't broken.
Match existing style, even if you'd do it differently.
If you notice unrelated dead code, mention it - don't delete it.
When your changes create orphans:

Remove imports/variables/functions that YOUR changes made unused.
Don't remove pre-existing dead code unless asked.
The test: Every changed line should trace directly to the user's request.

4. Goal-Driven Execution
Define success criteria. Loop until verified.

Transform tasks into verifiable goals:

"Add validation" → "Write tests for invalid inputs, then make them pass"
"Fix the bug" → "Write a test that reproduces it, then make it pass"
"Refactor X" → "Ensure tests pass before and after"
For multi-step tasks, state a brief plan:

1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

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
./scripts/k3s/deploy-cluster.sh --prod

# Deploy test cluster  
./scripts/k3s/deploy-cluster.sh --test

# Deploy staging cluster
./scripts/k3s/deploy-cluster.sh --stage
```

### Application Deployment

Applications are deployed by ArgoCD, not Ansible. To enable, disable, or modify
applications, edit the relevant manifests under `argocd/apps/<env>/` and
`argocd/manifests/**` and let ArgoCD reconcile from the environment's tracked
branch.

### Component Deployment
```bash
# Deploy individual infrastructure components (longhorn, metallb, traefik, argocd, vault)
./scripts/k3s/deploy-component.sh --prod traefik
./scripts/k3s/deploy-component.sh --prod metallb
./scripts/k3s/deploy-component.sh --prod longhorn

# Deploy all infra components in order (fresh cluster bootstrap)
./scripts/k3s/deploy-component.sh --prod all-infra

# Force redeploy (cleanup and reinstall)
./scripts/k3s/deploy-component.sh --prod traefik --force

# Dry run (show commands without executing)
./scripts/k3s/deploy-component.sh --prod traefik --dry-run

# List available components
./scripts/k3s/deploy-component.sh --list
```

For detailed troubleshooting and manual operations, see [docs/operations/cluster-operations.md](docs/operations/cluster-operations.md) and [docs/recovery/backup-and-restore.md](docs/recovery/backup-and-restore.md).

### Context Management
```bash
# Setup all cluster contexts
./scripts/k3s/helpers/k3s-context-manager.sh setup

# Switch between clusters
./scripts/k3s/helpers/k3s-context-manager.sh switch prod
./scripts/k3s/helpers/k3s-context-manager.sh switch test

# List available contexts
./scripts/k3s/helpers/k3s-context-manager.sh list
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
./scripts/maintenance/list-backups.sh
./scripts/maintenance/list-backups.sh --detailed
./scripts/maintenance/list-backups.sh --all

# Full disaster recovery for production
./scripts/maintenance/restore-cluster.sh --prod

# Clone production data to staging
./scripts/maintenance/restore-cluster.sh --stage --from prod

# Restore data only (no VM rebuild)
./scripts/maintenance/restore-cluster.sh --prod --restore-only

# Restore specific app only
./scripts/maintenance/restore-app.sh --stage --from prod --app bookstack
./scripts/maintenance/restore-app.sh --prod --pvc factorio-data
```

### Maintenance Power Cycle
```bash
# Graceful shutdown
./scripts/maintenance/shutdown-k3s-cluster.sh --stage

# Power VMs back on and run the restart workflow
./scripts/maintenance/power-on-k3s-cluster.sh --stage

# Restart services only when VMs are already online
./scripts/maintenance/restart-k3s-cluster.sh --stage
```

### Vault Management
```bash
# Edit K3s vault file
ansible-vault edit ansible/group_vars/k3s_cluster_vault.yml

# Edit shared Proxmox vault file
ansible-vault edit ansible/group_vars/proxmox_vault.yml

# Edit LXC vault file
ansible-vault edit ansible/group_vars/lxc_vault.yml

# View vault contents
ansible-vault view ansible/group_vars/k3s_cluster_vault.yml
ansible-vault view ansible/group_vars/proxmox_vault.yml
ansible-vault view ansible/group_vars/lxc_vault.yml
```

## Key Directory Structure

```
├── ansible/
│   ├── group_vars/              # Environment-specific variables
│   │   ├── k3s_cluster.yml      # K3s production config
│   │   ├── k3s_cluster_test.yml # K3s test config
│   │   ├── k3s_cluster_stage.yml# K3s staging config
│   │   ├── k3s_cluster_topology.yml # Node roles + Longhorn disk layout (all envs)
│   │   ├── k3s_cluster_vault.yml# K3s encrypted secrets
│   │   ├── lxc.yml              # LXC shared config
│   │   ├── lxc_vault.yml        # LXC encrypted secrets
│   │   ├── proxmox.yml          # Shared Proxmox config
│   │   └── proxmox_vault.yml    # Shared Proxmox encrypted secrets
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
│   ├── deploy-lxc.sh            # LXC container deployment
│   ├── helpers/                 # Shared helper utilities
│   │   ├── cluster-context-manager.sh
│   │   ├── generate-vaultwarden-token.sh
│   │   ├── manage-ssh-hosts.sh
│   │   ├── pod-describe.sh
│   │   └── pod-logs.sh
│   ├── k3s/                     # K3s deployment and helper scripts
│   │   ├── deploy-cluster.sh
│   │   ├── deploy-component.sh
│   │   ├── rebuild-cluster.sh
│   │   ├── reset-cluster.sh
│   │   └── helpers/
│   │       ├── create-k3s-monitoring-token.sh
│   │       ├── k3s-context-manager.sh
│   │       └── k3s-shell-functions.sh
│   ├── talos/                   # Talos deployment and helper scripts
│   │   ├── deploy-cluster.sh
│   │   └── helpers/
│   │       ├── import-talos-template.sh
│   │       ├── talos-context-manager.sh
│   │       └── talos-shell-functions.sh
│   ├── maintenance/             # Recovery and maintenance scripts
│   │   ├── list-backups.sh
│   │   ├── power-on-k3s-cluster.sh
│   │   ├── recover-vault.sh
│   │   ├── restart-k3s-cluster.sh
│   │   ├── shutdown-k3s-cluster.sh
│   │   ├── restore-app.sh
│   │   ├── restore-cluster.sh
│   │   └── update-k3s-nodes.sh
│   ├── lib/                     # Shared libraries
│   │   ├── environment-functions.sh
│   │   └── talos-environments.conf
└── docs/                        # Additional documentation
    └── CLUSTER_MANAGEMENT.md    # Operational runbook
```

## Multi-Environment Architecture

The repository supports three environments:

### Production (`--prod`)
- Cluster nodes: 172.20.20.101-107
- Domain: `levangie.dev` 
- High availability with Longhorn storage
- Production-grade applications

### Test (`--test`)  
- Cluster nodes: 172.20.21.121-124
- Domain: `test.levangie.dev`
- Simplified configuration for testing
- Safe environment for experiments

### Staging (`--stage`)
- Cluster nodes: 172.20.21.111-114  
- Domain: `stage.levangie.dev`
- Production-like testing environment

### Talos Test (experimental)
- Cluster nodes: 172.20.20.131-133
- Distribution: **Talos Linux** + upstream Kubernetes (not K3s, not Debian)
- Managed via `terraform/stacks/talos/test/` (uses the `siderolabs/talos` provider for bootstrap) and `scripts/talos/helpers/import-talos-template.sh` for the Atlas Proxmox template
- VMs have `start_at_node_boot = false` and do not start on Proxmox host boot
- No Ansible: Talos has no SSH/package manager; the existing `k3s` role does not apply here
- App deployment (kubectl/helm, ArgoCD) still works against the cluster API if/when wired up; not yet integrated with `scripts/k3s/helpers/k3s-context-manager.sh`

## Node Topology and Longhorn Storage Layout

`ansible/group_vars/k3s_cluster_topology.yml` is the single source of truth for
which nodes exist, what hardware class each one is, and which Longhorn disks it
should carry. It replaces the former per-host
`ansible/inventories/production/host_vars/k3s-prod-*.yml` files.

A **profile** describes a hardware class, not a host — workers built from the
same Terraform stack share one:

| Profile | Nodes | Longhorn disks |
|---------|-------|----------------|
| `atlas-worker` | prod worker-1/2/3 | flash (`scsi3`) + tank (`scsi2`) |
| `atlas-gpu-worker` | prod worker-gpu-1 | one disk at `/var/lib/longhorn` (`scsi1`) |
| `elitedesk-worker` | prod worker-4 | flash only (`scsi1`) |
| `control-plane` | prod cp-1/3/4 | none |
| `simple-node` | test + stage | unmanaged (Longhorn's own default disk) |

### Adding or removing a node

1. Provision or destroy the VM with the relevant Terraform stack.
2. Add the host to `ansible/inventories/<env>/hosts.yml`.
3. Add **one line** to `k3s_node_profile:` in the topology file pointing at the
   right profile.
4. Run the cluster deploy (or `deploy-component.sh <env> longhorn`).

Ansible mounts every disk the profile declares and reconciles the Longhorn node
CR to match — registering missing disks, correcting disk tags and node tags.

### Drift reporting

A disk registered in Longhorn that the topology does **not** declare is
reported and never removed:

```
DRIFT k3s-prod-cp-1: disk 'default-disk-...' at /var/lib/longhorn/ is registered
      in Longhorn but not declared in the node topology (not removed — evict by
      hand if unwanted)
```

Removal stays manual on purpose: a typo in a profile must never be able to
evict a real disk's replicas. To act on a report, disable scheduling and
request eviction on that disk, wait for replicas to drain, then remove it from
`spec.disks`.

Disks are matched by **path**, not by name — Longhorn disk names are arbitrary
map keys, so renaming one in the topology must not read as "remove this disk,
add another".

Hosts absent from `k3s_node_profile` fall back to `simple-node`, which touches
no disks. Profiles set `longhorn_manage_disks: false` to opt out of
reconciliation and drift reporting entirely (test and stage do this, preserving
their existing behaviour).

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
| **Stage** | `root-stage` | `argocd/apps/stage` | `stage` |
| **Test** | `root-test` | `argocd/apps/test` | `main` |

Operational guidance:
- Make environment-specific app enablement changes under `argocd/apps/<env>`
- Make shared manifest changes under `argocd/manifests/**`
- Use `stage` as the stage cluster's GitOps testing branch
- Promote validated stage changes into `main` for prod and test

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
./scripts/maintenance/list-backups.sh
./scripts/maintenance/list-backups.sh --detailed   # Show individual backup timestamps
./scripts/maintenance/list-backups.sh --all        # Show all volume instances

# Full disaster recovery (rebuild VMs + restore data)
./scripts/maintenance/restore-cluster.sh --prod

# Clone production data to staging
./scripts/maintenance/restore-cluster.sh --stage --from prod

# Restore data only to existing cluster
./scripts/maintenance/restore-cluster.sh --prod --restore-only

# Restore specific application
./scripts/maintenance/restore-app.sh --stage --from prod --app bookstack
./scripts/maintenance/restore-app.sh --prod --pvc factorio-data

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
The preferred shared Proxmox secrets file is `ansible/group_vars/proxmox_vault.yml`:
- `vault_proxmox_api_host`: Proxmox API endpoint
- `vault_proxmox_api_user`: API user
- `vault_proxmox_api_token_id`: API token ID
- `vault_proxmox_api_token_secret`: API token secret

`ansible/group_vars/lxc_vault.yml` contains:
- `vault_ssh_public_key`: SSH key for container access

## Troubleshooting

### General Issues
- **Context issues**: Run `./scripts/k3s/helpers/k3s-context-manager.sh setup` to refresh contexts
- **Vault errors**: Ensure `~/.ansible_vault_pass` contains the correct password
- **Deployment failures**: Check cluster connectivity and vault credentials
- **Storage issues**: Verify NFS server accessibility and Longhorn status

### LXC Issues
- **LXC template missing**: Run `./scripts/deploy-lxc.sh --template-only` to download template
- **LXC container unreachable**: Check Proxmox console for container IP (DHCP assigned)

### Backup/Restore Issues
- **Script won't execute**: Run `dos2unix scripts/maintenance/list-backups.sh scripts/maintenance/restore-cluster.sh` (Windows CRLF issue)
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

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:7510c1e2 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->
