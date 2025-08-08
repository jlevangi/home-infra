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

## 🚀 Quick Start

### 1. Clone and Configure
```bash
git clone <your-repo-url>
cd home-infra
```

### 2. Configure Terraform Variables
Edit `terraform/k3_3node_cluster/terraform.tfvars`:
```hcl
token_secret = "your-proxmox-api-token-secret"
token_id = "your-proxmox-api-token-id"
ssh_key = "your-ssh-public-key-content"
ci_password = "vm-user-password"
vault_password = "ansible-vault-password"
```

Update `terraform/k3_3node_cluster/variables.tf` for your environment:
```hcl
variable "api_url" {
    default = "https://YOUR-PROXMOX-IP:8006/api2/json"
}
variable "proxmox_hosts" {
    default = "YOUR-PROXMOX-NODE-NAME"
}
variable "template_name" {
    default = "debian12-server-template"  # Your template name
}
```

### 3. Configure Ansible Inventory
Update `ansible/k3s-inventory` with your desired IP addresses:
```ini
[k3s_master]
k3s-node-1 ansible_host=172.20.20.101 ansible_user=pierce ansible_ssh_private_key_file=~/.ssh/pierce

[k3s_workers]
k3s-node-2 ansible_host=172.20.20.102 ansible_user=pierce ansible_ssh_private_key_file=~/.ssh/pierce
k3s-node-3 ansible_host=172.20.20.103 ansible_user=pierce ansible_ssh_private_key_file=~/.ssh/pierce
```

### 4. Configure Ansible Vault
Create your encrypted configuration:
```bash
cd ansible
cp group_vars/k3s_cluster_vault.yml.example group_vars/k3s_cluster_vault.yml
ansible-vault edit group_vars/k3s_cluster_vault.yml
```

Required vault variables:
```yaml
vault_nfs_username: "k3s-service-user"
vault_nfs_password: "your-nfs-password"
vault_nfs_uid: "1024"
vault_nfs_gid: "100"
vault_nfs_share_root: "/volume1/k3s-storage"
vault_k3s_token: "your-secure-k3s-token"
```

### 5. Deploy Infrastructure
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
- **URL**: Configured via `vaultwarden_app_url` variable (default: `https://vw.levangie.org`)
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
