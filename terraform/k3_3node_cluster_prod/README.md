# K3s 3-Node Cluster Deployment

This Terraform configuration deploys a 3-node K3s Kubernetes cluster on Proxmox VE using cloud-init templates.

## Prerequisites

### 1. Terraform
- Install Terraform >= 1.0
- Download from: https://www.terraform.io/downloads

### 2. Ansible
- Install Ansible (preferably in WSL on Windows)
- Ubuntu/Debian: `sudo apt update && sudo apt install ansible`
- Or via pip: `pip install ansible`

### 3. Proxmox Setup
- Proxmox VE server with API access
- API token created (Instructions: https://pve.proxmox.com/wiki/User_Management#pveum_tokens)
- Cloud-init template named `debian12-server-template` (or update the template name in variables.tf)
- Template must support cloud-init and have qemu-guest-agent installed

### 4. SSH Key Setup
- Update the SSH key in `variables.tf` with your public key
- Ensure you have the corresponding private key for SSH access

### 5. Cloud-Init Template Requirements
Your Proxmox template should include:
- `cloud-init` package installed
- `qemu-guest-agent` installed and enabled
- SSH server enabled
- User with sudo privileges (will be configured via cloud-init)

## Configuration

### 1. Update Variables
Edit `variables.tf` to match your environment:
- `proxmox_hosts`: Your Proxmox node name
- `api_url`: Your Proxmox API URL
- `ssh_key`: Your SSH public key
- `template_name`: Your cloud-init template name

### 2. Set API Credentials
Update `terraform.tfvars` with your Proxmox API credentials:
```hcl
token_secret = "your-token-secret"
token_id = "your-token-id"
```

### 3. Network Configuration
The default configuration uses:
- Master node: `172.20.20.101`
- Worker nodes: `172.20.20.102`, `172.20.20.103`
- Gateway: `172.20.20.1`
- DNS servers: `172.20.20.4`, `172.20.20.5`

Update IP addresses in `main.tf` if needed to match your network.

## Deployment

### Option 1: Automated Deployment (Recommended)

#### Windows (PowerShell):
```powershell
.\deploy.ps1
```

#### Linux/WSL (Bash):
```bash
chmod +x deploy.sh
./deploy.sh
```

### Option 2: Manual Deployment

1. **Initialize Terraform:**
   ```bash
   terraform init
   ```

2. **Plan the deployment:**
   ```bash
   terraform plan
   ```

3. **Apply the configuration:**
   ```bash
   terraform apply
   ```

4. **Wait for VMs to boot (about 2-3 minutes)**

5. **Deploy K3s using Ansible:**
   ```bash
   cd ../ansible
   ansible-playbook -i k3s-inventory playbooks/k3s-deploy.yml
   ```

## Post-Deployment

### 1. Verify Cluster
SSH to the master node and check the cluster:
```bash
ssh k3s@172.20.20.101
kubectl get nodes -o wide
```

### 2. Access from Local Machine
Copy the kubeconfig file to your local machine:
```bash
scp k3s@172.20.20.101:~/.kube/config ~/.kube/k3s-config
export KUBECONFIG=~/.kube/k3s-config
kubectl get nodes
```

### 3. Deploy Sample Application
Test the cluster with a simple deployment:
```bash
kubectl create deployment nginx --image=nginx
kubectl expose deployment nginx --port=80 --type=NodePort
kubectl get services
```

## Architecture

The deployment creates:
- **1 Master Node** (k3s-node-1): Runs the K3s server with etcd
- **2 Worker Nodes** (k3s-node-2, k3s-node-3): Run the K3s agent

### VM Specifications:
- **CPU**: 2 cores per node
- **Memory**: 2GB per node (adjustable)
- **Storage**: 20GB per node (thin-provisioned)
- **Network**: Virtio with static IP configuration

### Cloud-Init Configuration:
Each node is automatically configured with:
- **System updates** and essential packages
- **DNS configuration** (172.20.20.4/5 with fallback)
- **Kernel modules** for Kubernetes (br_netfilter, overlay)
- **Sysctl settings** for optimal Kubernetes performance
- **Swap disabled** (required for Kubernetes)
- **Directory structure** for K3s and local storage
- **kubectl** installed with bash completion and aliases
- **Firewall disabled** for simplified networking

## Customization

### Scaling
To change the number of nodes, update `vm_count` in `variables.tf` and adjust the Ansible inventory accordingly.

### Resources
Modify CPU, memory, and storage in `main.tf`:
```hcl
cores = 4        # Increase CPU cores
memory = 4096    # Increase memory (MB)
size = "40G"     # Increase disk size
```

### K3s Configuration
Modify the K3s installation in `ansible/playbooks/k3s-deploy.yml`:
- Change K3s version
- Add/remove K3s server arguments
- Configure additional features

## Troubleshooting

### Common Issues

1. **SSH Connection Failed**
   - Verify the cloud-init template has the correct SSH key
   - Check if the VMs have booted completely
   - Verify network connectivity

2. **Ansible Playbook Fails**
   - Ensure all VMs are accessible via SSH
   - Check the inventory file has correct IP addresses
   - Verify Ansible is installed and working

3. **K3s Installation Fails**
   - Check internet connectivity on VMs
   - Verify the K3s version is available
   - Check system resources (memory, disk space)

### Cleanup
To destroy the cluster:
```bash
terraform destroy
```

## Security Considerations

1. **Change Default Passwords**: Update the default `k3s` user password
2. **SSH Key Security**: Use strong SSH keys and consider key rotation
3. **Network Security**: Configure firewalls and network segmentation
4. **API Token Security**: Use minimal permissions for Proxmox API tokens
5. **K3s Token**: Change the default K3s token in the Ansible playbook

## Version Information

- **Terraform Proxmox Provider**: ~> 3.0
- **K3s Version**: v1.28.5+k3s1 (configurable in Ansible playbook)
- **Terraform**: >= 1.0

## Support

For issues and questions:
1. Check the Terraform and Ansible logs
2. Verify Proxmox API connectivity
3. Test VM accessibility via SSH
4. Review K3s installation logs on the nodes
