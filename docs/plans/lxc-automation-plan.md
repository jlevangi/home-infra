# LXC Container Automation Plan

## Overview

Add Ansible-based LXC container automation to the home-infra repository. This will allow declarative definition of LXC containers via YAML files, with optional Docker installation support.

**Key Design Decisions:**
- Ansible-only approach (no Terraform) using `community.general.proxmox` module
- Per-container YAML definition files
- Separate template configuration for easy management
- Single environment (no prod/test/stage split)
- Unprivileged containers with nesting enabled for Docker support

---

## Directory Structure

```
ansible/
├── lxc_definitions/
│   ├── templates/
│   │   └── ubuntu-24.04.yml          # Template definition (ID 9001)
│   └── containers/
│       └── nbn-srv.yml               # First container definition
├── inventories/
│   └── lxc/
│       └── hosts.yml                 # LXC container inventory
├── roles/
│   └── lxc/
│       ├── tasks/
│       │   ├── main.yml              # Task orchestration
│       │   ├── template.yml          # Download/prepare LXC template
│       │   ├── create.yml            # Create container from template
│       │   ├── configure.yml         # Users, SSH keys, base config
│       │   └── docker.yml            # Install Docker + Compose
│       ├── defaults/
│       │   └── main.yml              # Default variable values
│       ├── handlers/
│       │   └── main.yml              # Handlers (container restart, etc.)
│       └── templates/
│           └── docker-daemon.json.j2 # Docker daemon config (if needed)
├── playbooks/
│   └── lxc-deploy.yml                # Main LXC deployment playbook
└── group_vars/
    └── lxc.yml                       # Shared LXC variables

scripts/
└── deploy_lxc.sh                     # Deployment wrapper script
```

---

## Implementation Steps

### Phase 1: Foundation

#### 1.1 Create LXC Role Structure
Create the `ansible/roles/lxc/` directory with all required subdirectories and files.

**Files to create:**
- `ansible/roles/lxc/defaults/main.yml` - Default values
- `ansible/roles/lxc/handlers/main.yml` - Handlers
- `ansible/roles/lxc/tasks/main.yml` - Main task orchestration

#### 1.2 Create Template Definition System
Define the Ubuntu 24.04 LXC template configuration.

**File:** `ansible/lxc_definitions/templates/ubuntu-24.04.yml`
```yaml
template_name: ubuntu-24.04
template_id: 9001
description: "Ubuntu 24.04 LTS LXC Template"

# Official LXC image source
source:
  distribution: ubuntu
  release: noble
  architecture: amd64

# Proxmox storage location for template
storage: local

# Template download URL (constructed from source or override)
# Uses: https://images.linuxcontainers.org/
```

#### 1.3 Create Template Download Task
**File:** `ansible/roles/lxc/tasks/template.yml`

This task will:
1. Check if template already exists on Proxmox node
2. Download from official LXC image server if missing
3. Use `pveam` command to download template

---

### Phase 2: Container Creation

#### 2.1 Create Container Definition Format
**File:** `ansible/lxc_definitions/containers/nbn-srv.yml`
```yaml
# Container identification
container_name: nbn-srv
container_id: 200
description: "Hugo website hosting via Docker"

# Proxmox settings
node: pve1
template: ubuntu-24.04

# Resource allocation
resources:
  cores: 2
  memory: 2048      # MB
  swap: 512         # MB
  disk_size: 16     # GB
  storage: local-lvm

# Network configuration
network:
  bridge: vmbr0
  dhcp: true
  # Optional static IP (uncomment to use)
  # ip: 172.20.20.50/24
  # gateway: 172.20.20.1
  nameservers:
    - 172.20.20.4
    - 172.20.20.5

# Container features
features:
  unprivileged: true
  nesting: true           # Required for Docker

# Application features (controls what gets installed)
applications:
  docker_installed: true

# Future: Application-specific config
# app_config:
#   hugo_site_path: /var/www/hugo
```

#### 2.2 Create Container Creation Task
**File:** `ansible/roles/lxc/tasks/create.yml`

This task will:
1. Load container definition from YAML file
2. Check if container already exists
3. Create container using `community.general.proxmox` module
4. Start the container
5. Wait for container to be accessible via SSH

---

### Phase 3: Container Configuration

#### 3.1 Create User Configuration Task
**File:** `ansible/roles/lxc/tasks/configure.yml`

This task will:
1. Create a primary admin user with sudo privileges
2. Create `ansible` user for configuration management
3. Deploy SSH authorized keys (from vault)
4. Configure sudo access (passwordless for ansible user)
5. Set hostname and /etc/hosts
6. Configure DNS nameservers
7. Update apt cache and install base packages

#### 3.2 Create Docker Installation Task
**File:** `ansible/roles/lxc/tasks/docker.yml`

This task will (when `docker_installed: true`):
1. Install Docker prerequisites
2. Add Docker GPG key and repository
3. Install Docker CE and Docker Compose plugin
4. Add users to docker group
5. Enable and start Docker service
6. Verify Docker is working

---

### Phase 4: Inventory and Playbook

#### 4.1 Create LXC Inventory
**File:** `ansible/inventories/lxc/hosts.yml`
```yaml
---
lxc_containers:
  hosts:
    nbn-srv:
      ansible_host: nbn-srv.local  # Or IP after DHCP assignment
      # Container-specific vars can go here

  vars:
    ansible_user: ansible
    ansible_become: true
    ansible_python_interpreter: /usr/bin/python3
```

#### 4.2 Create Group Variables
**File:** `ansible/group_vars/lxc.yml`
```yaml
---
# Proxmox connection settings
proxmox_node: pve1
proxmox_api_host: "{{ vault_proxmox_api_host }}"
proxmox_api_user: "{{ vault_proxmox_api_user }}"
proxmox_api_token_id: "{{ vault_proxmox_api_token_id }}"
proxmox_api_token_secret: "{{ vault_proxmox_api_token_secret }}"

# Default LXC settings
lxc_default_storage: local-lvm
lxc_default_bridge: vmbr0
lxc_default_cores: 2
lxc_default_memory: 2048
lxc_default_swap: 512
lxc_default_disk_size: 16

# Network defaults
lxc_gateway: 172.20.20.1
lxc_nameservers:
  - 172.20.20.4
  - 172.20.20.5

# User configuration
lxc_users:
  - name: <primary-admin-user>
    groups: sudo
    shell: /bin/bash
  - name: ansible
    groups: sudo
    shell: /bin/bash

lxc_ssh_public_key: "{{ vault_ssh_public_key }}"

# Template definitions path
lxc_definitions_path: "{{ playbook_dir }}/../lxc_definitions"
```

#### 4.3 Create Main Playbook
**File:** `ansible/playbooks/lxc-deploy.yml`
```yaml
---
- name: Deploy LXC Container
  hosts: localhost
  gather_facts: false
  vars_files:
    - ../group_vars/k3s_cluster_vault.yml
    - ../group_vars/lxc.yml

  tasks:
    - name: Load container definition
      include_vars:
        file: "{{ lxc_definitions_path }}/containers/{{ container_name }}.yml"
        name: container

    - name: Load template definition
      include_vars:
        file: "{{ lxc_definitions_path }}/templates/{{ container.template }}.yml"
        name: template

    - name: Ensure template exists
      include_role:
        name: lxc
        tasks_from: template.yml

    - name: Create container
      include_role:
        name: lxc
        tasks_from: create.yml

- name: Configure LXC Container
  hosts: "{{ container_name }}"
  gather_facts: true
  vars_files:
    - ../group_vars/k3s_cluster_vault.yml
    - ../group_vars/lxc.yml

  pre_tasks:
    - name: Load container definition
      include_vars:
        file: "{{ lxc_definitions_path }}/containers/{{ container_name }}.yml"
        name: container
      delegate_to: localhost

  roles:
    - role: lxc
```

---

### Phase 5: Deployment Script

#### 5.1 Create Deploy Script
**File:** `scripts/deploy-lxc.sh`

Features:
- List available containers from `ansible/lxc_definitions/containers/`
- Interactive selection or specify container name as argument
- Support for `--list` to show available containers
- Support for `--template-only` to just prepare template
- Support for `--skip-template` to skip template check
- Colored output matching existing script style
- Vault password file integration

**Usage examples:**
```bash
# List available containers
./scripts/deploy-lxc.sh --list

# Deploy specific container
./scripts/deploy-lxc.sh nbn-srv

# Interactive selection
./scripts/deploy-lxc.sh

# Prepare template only
./scripts/deploy-lxc.sh --template-only ubuntu-24.04
```

---

### Phase 6: Vault Updates

#### 6.1 Verify/Add Required Vault Variables
Ensure these exist in `ansible/group_vars/k3s_cluster_vault.yml`:
- `vault_proxmox_api_host` (if not already present)
- `vault_proxmox_api_user` (if not already present)
- `vault_proxmox_api_token_id`
- `vault_proxmox_api_token_secret`
- `vault_ssh_public_key`

---

## File Checklist

### New Files to Create

| File | Purpose |
|------|---------|
| `ansible/roles/lxc/defaults/main.yml` | Default variable values |
| `ansible/roles/lxc/handlers/main.yml` | Handlers for container operations |
| `ansible/roles/lxc/tasks/main.yml` | Main task orchestration |
| `ansible/roles/lxc/tasks/template.yml` | Template download/preparation |
| `ansible/roles/lxc/tasks/create.yml` | Container creation |
| `ansible/roles/lxc/tasks/configure.yml` | User/SSH/base configuration |
| `ansible/roles/lxc/tasks/docker.yml` | Docker installation |
| `ansible/roles/lxc/templates/docker-daemon.json.j2` | Docker daemon config (optional) |
| `ansible/lxc_definitions/templates/ubuntu-24.04.yml` | Ubuntu template definition |
| `ansible/lxc_definitions/containers/nbn-srv.yml` | First container definition |
| `ansible/inventories/lxc/hosts.yml` | LXC inventory file |
| `ansible/group_vars/lxc.yml` | Shared LXC variables |
| `ansible/playbooks/lxc-deploy.yml` | Main deployment playbook |
| `scripts/deploy-lxc.sh` | Deployment wrapper script |

### Files to Modify

| File | Change |
|------|--------|
| `ansible/group_vars/k3s_cluster_vault.yml` | Add Proxmox API credentials if missing |
| `CLAUDE.md` | Add LXC section with commands and structure |

---

## Dependencies

### Ansible Collections Required
```bash
ansible-galaxy collection install community.general
```

The `community.general.proxmox` module requires:
- `proxmoxer` Python library on control node
- `requests` Python library on control node

```bash
pip install proxmoxer requests
```

---

## Testing Plan

1. **Template Download Test**
   - Run template task in check mode
   - Verify template downloads to Proxmox

2. **Container Creation Test**
   - Create nbn-srv container
   - Verify container starts and is accessible

3. **Configuration Test**
   - Verify users created with correct permissions
   - Verify SSH access works for both users
   - Verify sudo works

4. **Docker Test**
   - Verify Docker installed and running
   - Run `docker run hello-world` test
   - Verify docker-compose works

---

## Future Enhancements (Out of Scope)

- Application deployment tasks (Hugo, Caddy, etc.)
- Container backup/snapshot automation
- Resource monitoring integration
- Multi-node support with shared storage
- Container migration capabilities
- Automated DNS registration
