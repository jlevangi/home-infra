# Home Infrastructure Automation

A comprehensive infrastructure-as-code solution for deploying a production-ready K3s Kubernetes cluster on Proxmox VE using Terraform and Ansible. This repository provides automated provisioning, configuration, and application deployment for a home lab or small enterprise environment.

## 🏗️ Architecture Overview

This infrastructure consists of:
- **Terraform**: Provisions 3-node K3s cluster VMs on Proxmox VE using cloud-init templates
- **Ansible**: Configures nodes and deploys K3s with advanced networking, storage, and ingress
- **K3s Kubernetes**: Lightweight, production-ready Kubernetes distribution
- **Traefik**: Advanced ingress controller with SSL termination and dashboard
- **MetalLB**: Load balancer for bare metal Kubernetes
- **NFS Storage**: Shared persistent storage integration

## 📋 Prerequisites

### Required Infrastructure
- **Proxmox VE** server with API access and API token configured
- **NFS Storage** (Synology NAS or similar) for persistent volumes
- **Network**: VLAN/subnet with static IP assignments for cluster nodes
- **Template VM**: Debian 12 cloud-init template with qemu-guest-agent

### Required Software
- **Terraform** >= 1.0 ([Download](https://www.terraform.io/downloads))
- **Ansible** (preferably in WSL on Windows)
- **SSH keys** configured for VM access
- **kubectl** for cluster management

### Proxmox Template Requirements
Your Proxmox cloud-init template must include:
- `cloud-init` package installed
- `qemu-guest-agent` installed and enabled
- SSH server enabled and configured
- User with sudo privileges (configured via cloud-init)
- Python3 for Ansible compatibility

## 🔧 USING IN YOUR ENVIRONMENT

This section covers all the variables and configurations you'll need to customize to deploy this infrastructure in your specific environment.

### 1. Terraform Variables

#### Edit `terraform/k3_3node_cluster/terraform.tfvars`
**Critical Variables (Must Change):**
```hcl
# Proxmox API credentials (get from Proxmox web UI)
token_secret = "your-proxmox-api-token-secret"
token_id = "your-proxmox-api-token-id@realm!token-name"

# SSH access (your public key content)
ssh_key = "ssh-ed25519 AAAAC3NzaC1... your-key-here"

# VM user password (for cloud-init user)
ci_password = "your-vm-password"

# Ansible vault password (to decrypt secrets)
vault_password = "your-ansible-vault-password"
```

#### Edit `terraform/k3_3node_cluster/variables.tf`
**Environment-Specific Variables:**
```hcl
# Your Proxmox server API URL
variable "api_url" {
    default = "https://YOUR-PROXMOX-IP:8006/api2/json"
}

# Your Proxmox node name
variable "proxmox_hosts" {
    default = "YOUR-PROXMOX-NODE-NAME"  # e.g., "pve1"
}

# Your cloud-init template name
variable "template_name" {
    default = "your-template-name"  # e.g., "debian12-server-template"
}

# Your network interface (if not vmbr0)
variable "nic_name" {
    default = "vmbr0"  # Change if using different bridge
}

# Your VLAN (if not default)
variable "vlan_num" {
    default = "1"  # Change to your VLAN ID
}

# Cloud-init username (change if desired)
variable "ci_user" {
    default = "your-username"  # Will be created on VMs
}
```

### 2. Ansible Inventory Configuration

#### Edit `ansible/k3s-inventory`
**IP Address Configuration (Critical if not using 172.20.20.x network):**
```ini
[k3s_master]
k3s-node-1 ansible_host=YOUR.MASTER.IP.HERE ansible_user=your-username ansible_ssh_private_key_file=~/.ssh/your-key

[k3s_workers]
k3s-node-2 ansible_host=YOUR.WORKER1.IP.HERE ansible_user=your-username ansible_ssh_private_key_file=~/.ssh/your-key
k3s-node-3 ansible_host=YOUR.WORKER2.IP.HERE ansible_user=your-username ansible_ssh_private_key_file=~/.ssh/your-key
```

### 3. Ansible Group Variables

#### Edit `ansible/group_vars/k3s_cluster.yml`
**Network Configuration (Critical if not using 172.20.20.x):**
```yaml
# MetalLB IP range - MUST be in your network range
metallb_ip_range: "YOUR.NETWORK.START-YOUR.NETWORK.END"
# Example: "192.168.1.200-192.168.1.210" if using 192.168.1.x

# Your domain/TLD for applications
cluster_tld: "your-domain.com"

# SMTP configuration (if you want email notifications)
smtp_host: "your-smtp-server.com"
smtp_from: "your-email@your-domain.com"
```

### 4. Ansible Vault Secrets

#### Create and edit `ansible/group_vars/k3s_cluster_vault.yml`
```bash
cd ansible
cp group_vars/k3s_cluster_vault.yml.example group_vars/k3s_cluster_vault.yml
ansible-vault edit group_vars/k3s_cluster_vault.yml
```

**Required Vault Variables:**
```yaml
# NFS Server Configuration (Critical)
vault_nfs_server: "YOUR.NFS.SERVER.IP"  # Your NAS/NFS server IP
vault_nfs_username: "your-nfs-username"  # NFS service account
vault_nfs_password: "your-nfs-password"
vault_nfs_uid: "1024"  # UID of your NFS user (check with `id username`)
vault_nfs_gid: "100"   # GID of your NFS user group
vault_nfs_share_root: "/volume1/k3s-storage"  # Your NFS export path

# K3s Cluster Security
vault_k3s_token: "your-secure-k3s-cluster-token"  # Generate a secure random token

# SMTP Configuration (for application notifications)
vault_smtp_host: "your-smtp-server.com"
vault_smtp_username: "your-smtp-username"
vault_smtp_password: "your-smtp-password"

# Application-specific secrets (if deploying apps)
vault_bookstack_db_password: "secure-database-password"
vault_bookstack_mysql_root_password: "secure-root-password"
vault_bookstack_app_key: "base64:your-32-char-app-key-here"
vault_vaultwarden_admin_token: "$argon2id$v=19$m=19456,t=2,p=1$YOUR_ARGON2_HASH"
```

### 5. Network-Specific Considerations

**If you're NOT using 172.20.20.x network:**

1. **Update all IP references** in:
   - `ansible/k3s-inventory` (node IPs)
   - `ansible/group_vars/k3s_cluster.yml` (MetalLB range)
   - `terraform/k3_3node_cluster/variables.tf` (Proxmox API URL)

2. **Ensure your network supports:**
   - Static IP assignments for cluster nodes
   - Inter-node communication on required ports
   - NFS connectivity to your storage server

### 6. Quick Environment Check

Before deployment, verify:
```bash
# Can reach your Proxmox API
curl -k https://YOUR-PROXMOX-IP:8006/api2/json/version

# Can reach your NFS server
ping YOUR-NFS-SERVER-IP
showmount -e YOUR-NFS-SERVER-IP

# SSH key is working
ssh-add -l

# Ansible vault password is correct
ansible-vault view ansible/group_vars/k3s_cluster_vault.yml
```

## 🚀 Quick Start

### 1. Clone Repository
```bash
git clone <your-repo-url>
cd home-infra
```

### 2. Configure Your Environment
Follow the **[USING IN YOUR ENVIRONMENT](#-using-in-your-environment)** section above to customize all variables for your specific setup.

### 3. Deploy Infrastructure
```bash
# Deploy VMs with Terraform
cd terraform/k3_3node_cluster
terraform init
terraform plan
terraform apply

# Configure and deploy K3s cluster
cd ../../scripts
./redeploy_k3s_roles.sh
```

### 4. Verify Deployment
```bash
# Configure local kubectl access
./scripts/setup-local-kubeconfig.sh

# Verify cluster status
kubectl get nodes
kubectl get pods -A
```

### 5. Deploy Applications (Optional)
```bash
./scripts/deploy_k3s_apps.sh
```

## 📂 Documentation & Cluster Management

### Advanced Cluster Management Tools

The `docs/` folder contains detailed guides for advanced cluster operations, including:

**[K3s Cluster Management](docs/K3S-CLUSTER-MANAGEMENT.md)** - Comprehensive guide for managing multiple clusters with:
- **Context Switching**: Easy switching between production and test clusters
- **Shell Functions**: Convenient command-line aliases for cluster operations
- **Enhanced kubectl**: Context-aware kubectl commands with visual indicators

#### Quick Setup for Multi-Cluster Management
```bash
# Setup all cluster contexts (production & test)
./scripts/k3s-context-manager.sh setup

# Add shell functions to your profile
echo 'source /path/to/home-infra/scripts/k3s-shell-functions.sh' >> ~/.bashrc

# Reload your shell and use convenient commands
k3s-prod     # Switch to production cluster
k3s-test     # Switch to test cluster
k3s-status   # Show current cluster info
kinfo        # Enhanced cluster information
```

#### Available Management Commands
- `k3s-prod` / `k3s-test` - Switch between clusters
- `k3s-setup` - Setup/refresh all cluster contexts
- `k3s-list` - List all available contexts
- `kinfo` - Show detailed cluster information
- `k` - Context-aware kubectl with cluster display

This system eliminates kubeconfig conflicts and makes multi-cluster operations seamless.

## 🛠️ Configuration Details

### Terraform Configuration

The Terraform deployment creates:
- **3 VMs**: 1 master + 2 worker nodes
- **Cloud-init**: Automated VM configuration
- **Network**: Static IP assignments on specified VLAN
- **Storage**: VM disks on Proxmox storage

Key variables in `terraform/k3_3node_cluster/variables.tf`:
- `vm_count`: Number of VMs to create (default: 3)
- `vm_name`: VM name prefix (default: "k3s-node")
- `nic_name`: Network interface (default: "vmbr0")
- `vlan_num`: VLAN tag (default: "1")

### Ansible Configuration

#### Main Variables (`ansible/group_vars/k3s_cluster.yml`)
```yaml
k3s_version: "v1.28.5+k3s1"              # K3s version
k3s_cluster_cidr: "10.42.0.0/16"         # Pod network CIDR
k3s_service_cidr: "10.43.0.0/16"         # Service network CIDR
enable_nfs_storage: true                 # Enable NFS integration
nfs_server: "172.20.20.5"               # NFS server IP
```

#### Vault Variables (Encrypted)
Store sensitive data in `ansible/group_vars/k3s_cluster_vault.yml`:
- NFS credentials and paths
- K3s cluster tokens
- Application secrets

### Network Architecture

Default network configuration:
- **Master Node**: 172.20.20.101
- **Worker Nodes**: 172.20.20.102-103
- **MetalLB Pool**: Configure in `ansible/roles/k3s/templates/metallb-config.yaml.j2`
- **Traefik LoadBalancer**: Auto-assigned IP from MetalLB pool

## 📜 Setup Scripts

### `scripts/redeploy_k3s_roles.sh`
Primary deployment script that runs the complete Ansible playbook:
```bash
ansible-playbook -i ../ansible/k3s-inventory ../ansible/playbooks/k3s-deploy-roles.yml --ask-vault-pass
```

### `scripts/setup-local-kubeconfig.sh`
Automatically configures local kubectl access:
- Downloads kubeconfig from master node
- Configures local ~/.kube/config
- Tests cluster connectivity

### `scripts/deploy_K3s_apps.sh`
Deploys applications after cluster setup:
```bash
ansible-playbook -i ../ansible/k3s-inventory ../ansible/playbooks/k3s-deploy-apps.yml --vault-password-file ~/.ansible_vault_pass
```

### `scripts/update_k3s_nodes.sh`
Updates and maintains cluster nodes.

## 🔧 Advanced Configuration

### NFS Storage Integration
Configure shared storage for persistent volumes:
1. Setup NFS server (Synology NAS recommended)
2. Create service user with appropriate permissions
3. Configure NFS exports
4. Update vault variables with NFS credentials

### Traefik Ingress Controller
Automated deployment includes:
- **SSL-ready ingress** with automatic certificate management
- **Dashboard access** at `http://<loadbalancer-ip>/dashboard/`
- **IngressRoute CRDs** for advanced routing
- **MetalLB integration** for load balancer IP assignment

### MetalLB Load Balancer
Provides external IP addresses for services:
- Configure IP pool in MetalLB template
- Automatic IP assignment for LoadBalancer services
- Integration with Traefik for ingress traffic

## 📱 Available Applications

This infrastructure includes several pre-configured applications that can be deployed on your K3s cluster:

### BookStack
A self-hosted wiki and documentation platform.
- **URL**: Configured via `bookstack_app_url` variable
- **Database**: MySQL with persistent NFS storage
- **Features**: WYSIWYG editor, user management, search functionality
- **Deployment**: Included in main application playbook

### Homepage Dashboard
A modern application dashboard with service discovery.
- **URL**: Configured via `homepage_app_url` variable
- **Features**: Service monitoring, bookmark management, Kubernetes integration
- **Storage**: Lightweight with configmap-based configuration
- **Deployment**: Included in main application playbook

### Vaultwarden
A lightweight, self-hosted Bitwarden-compatible password manager.
- **URL**: Configured via `vaultwarden_app_url` variable)
- **Database**: SQLite with NFS-backed storage
- **Features**: Password management, secure sharing, mobile app support
- **Security**: Argon2-hashed admin tokens, disabled public signups
- **Deployment**: Helm-based using guerzon/vaultwarden chart
- **Documentation**: See `docs/VAULTWARDEN.md` for detailed setup guide

### Application Deployment

Deploy all configured applications:
```bash
./scripts/deploy_k3s_apps.sh
```

Or deploy individual applications by setting deployment flags in `ansible/roles/k3s-apps/defaults/main.yml`:
```yaml
deploy_bookstack: true
deploy_homepage: true
deploy_vaultwarden: true
```

Each application includes:
- Force redeploy capability for clean updates
- NFS-backed persistent storage
- Traefik ingress with automatic SSL
- Health checks and resource limits
- Ansible vault integration for secrets

## 🔐 Security Best Practices

### Ansible Vault
All sensitive data is encrypted using Ansible Vault:
```bash
# Edit vault file
ansible-vault edit group_vars/k3s_cluster_vault.yml

# Change vault password
ansible-vault rekey group_vars/k3s_cluster_vault.yml
```

### SSH Key Management
- Use dedicated SSH keys for infrastructure
- Configure key-based authentication only
- Disable password authentication on VMs

### Network Security
- Use VLANs to isolate cluster traffic
- Configure firewall rules on Proxmox/router
- Implement network policies in Kubernetes

## 🚨 Troubleshooting

### Common Issues

**Terraform deployment fails:**
- Verify Proxmox API credentials and permissions
- Check template availability and cloud-init support
- Ensure network/VLAN configuration is correct

**Ansible deployment fails:**
- Verify SSH connectivity to all nodes
- Check vault password and encrypted variables
- Ensure Python3 is installed on target VMs

**K3s cluster issues:**
- Check node connectivity and firewall rules
- Verify NFS server accessibility
- Review systemd logs: `journalctl -u k3s`

### Verification Commands
```bash
# Check cluster status
kubectl get nodes
kubectl get pods -A

# Verify Traefik
kubectl get svc -n traefik-system
kubectl get pods -n traefik-system

# Check storage
kubectl get storageclass
kubectl get pv
```

## 🎯 Post-Deployment

After successful deployment:
1. **Configure DNS** entries for your services
2. **Setup SSL certificates** for production domains
3. **Deploy applications** using the provided app playbooks
4. **Configure monitoring** and logging solutions
5. **Implement backup** strategies for persistent data

## 📚 Additional Resources

- [K3s Documentation](https://docs.k3s.io/)
- [Traefik Documentation](https://doc.traefik.io/traefik/)
- [Ansible Vault Guide](https://docs.ansible.com/ansible/latest/user_guide/vault.html)
- [Proxmox VE API](https://pve.proxmox.com/wiki/Proxmox_VE_API)
