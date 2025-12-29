# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a **home infrastructure automation repository** that provides infrastructure-as-code for deploying production-ready K3s Kubernetes clusters on Proxmox VE. The repository manages multiple environments (production, test, staging) with automated provisioning, configuration, and application deployment.

## Architecture

- **Terraform**: VM provisioning on Proxmox VE with cloud-init templates
- **Ansible**: Configuration management, K3s deployment, and LXC container management
- **K3s Kubernetes**: Lightweight Kubernetes distribution
- **Longhorn**: Distributed storage with cross-cluster backup
- **Traefik**: Ingress controller with SSL termination
- **MetalLB**: Load balancer for bare metal Kubernetes
- **NFS Storage**: Backup target and legacy storage integration
- **LXC Containers**: Lightweight containers for standalone services (Docker-capable)

## Common Commands

### Cluster Deployment
```bash
# Deploy production cluster
./scripts/deploy_k3s_cluster.sh --prod

# Deploy test cluster  
./scripts/deploy_k3s_cluster.sh --test

# Deploy staging cluster
./scripts/deploy_k3s_cluster.sh --stage
```

### Application Deployment
```bash
# Deploy apps to production
./scripts/deploy_k3s_apps.sh --prod

# Deploy apps to test environment
./scripts/deploy_k3s_apps.sh --test
```

### Context Management
```bash
# Setup all cluster contexts
./scripts/k3s-context-manager.sh setup

# Switch between clusters
./scripts/k3s-context-manager.sh switch prod
./scripts/k3s-context-manager.sh switch test

# List available contexts
./scripts/k3s-context-manager.sh list
```

### LXC Container Deployment
```bash
# List available container definitions
./scripts/deploy_lxc.sh --list

# Deploy a specific container
./scripts/deploy_lxc.sh nbn-srv

# Interactive container selection
./scripts/deploy_lxc.sh

# Deploy with verbose output
./scripts/deploy_lxc.sh nbn-srv -v
```

### Terraform Operations
```bash
# Deploy production VMs
cd terraform/k3_3node_cluster_prod
terraform init
terraform plan
terraform apply

# Deploy test VMs
cd terraform/k3_3node_cluster_test
terraform init && terraform plan && terraform apply
```

### Ansible Operations
```bash
# Run cluster deployment playbook directly
ansible-playbook -i ansible/inventories/production/hosts.yml ansible/playbooks/k3s-deploy-cluster.yml --vault-password-file ~/.ansible_vault_pass

# Run app deployment playbook directly
ansible-playbook -i ansible/inventories/production/hosts.yml ansible/playbooks/k3s-deploy-apps.yml --vault-password-file ~/.ansible_vault_pass
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
│   │   ├── k3s-deploy-apps.yml
│   │   └── lxc-deploy.yml       # LXC deployment playbook
│   └── roles/                   # Ansible roles
│       ├── common/
│       ├── k3s/
│       ├── k3s-apps/
│       └── lxc/                 # LXC container role
├── terraform/                   # Infrastructure provisioning (VMs only)
│   ├── k3_3node_cluster_prod/
│   ├── k3_3node_cluster_test/
│   └── k3_3node_cluster_stage/
├── scripts/                     # Management scripts
│   ├── deploy_k3s_cluster.sh    # K3s cluster deployment
│   ├── deploy_k3s_apps.sh       # K3s application deployment
│   ├── deploy_lxc.sh            # LXC container deployment
│   ├── k3s-context-manager.sh   # Context switching
│   └── environment-functions.sh # Environment helpers
└── docs/                        # Additional documentation
```

## Multi-Environment Architecture

The repository supports three environments:

### Production (`--prod`)
- Cluster nodes: 172.20.20.101-103
- Domain: `levangie.dev` 
- High availability with Longhorn storage
- Production-grade applications

### Test (`--test`)  
- Cluster nodes: 172.20.20.121-123
- Domain: `test.levangie.dev`
- Simplified configuration for testing
- Safe environment for experiments

### Staging (`--stage`)
- Cluster nodes: 172.20.20.111-113  
- Domain: `stage.levangie.dev`
- Production-like testing environment

## Application Configuration

Applications are configured in `ansible/group_vars/k3s_cluster*.yml` files using a standardized structure:

```yaml
applications:
  app_name:
    deploy: true/false
    force_redeploy: true/false
    app_url: "https://app.domain.com"
    service_name: "app-service"
    service_port: 80
    storage:
      max_namespace_storage: "10Gi"
      default_pvc_size: "5Gi"
    secrets:
      key: "{{ vault_secret }}"
```

Available applications:
- **BookStack**: Documentation platform
- **Vaultwarden**: Password manager  
- **Homepage**: Dashboard
- **Plex**: Media server (Helm-based)

## Vault Password Management

All sensitive data is encrypted using Ansible Vault. The vault password should be stored in `~/.ansible_vault_pass` for automated operations.

Required vault variables are documented in `REQUIRED_VAULT_CREDENTIALS.md`.

## Development Workflow

1. **Infrastructure Changes**: Modify Terraform configurations in environment-specific directories
2. **Configuration Changes**: Update Ansible group_vars files for each environment
3. **Application Changes**: Modify Ansible roles in `ansible/roles/k3s-apps/`
4. **Secrets Management**: Use `ansible-vault edit` for sensitive data
5. **Testing**: Deploy to test environment first using `--test` flag
6. **Production**: Deploy to production using `--prod` flag after testing

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
3. Run `./scripts/deploy_lxc.sh <container-name>`

### LXC Vault Variables
The `ansible/group_vars/lxc_vault.yml` contains:
- `vault_proxmox_api_host`: Proxmox API endpoint
- `vault_proxmox_api_user`: API user
- `vault_proxmox_api_token_id`: API token ID
- `vault_proxmox_api_token_secret`: API token secret
- `vault_ssh_public_key`: SSH key for container access

## Troubleshooting

- **Context issues**: Run `./scripts/k3s-context-manager.sh setup` to refresh contexts
- **Vault errors**: Ensure `~/.ansible_vault_pass` contains the correct password
- **Deployment failures**: Check cluster connectivity and vault credentials
- **Storage issues**: Verify NFS server accessibility and Longhorn status
- **LXC template missing**: Run `./scripts/deploy_lxc.sh --template-only` to download template
- **LXC container unreachable**: Check Proxmox console for container IP (DHCP assigned)