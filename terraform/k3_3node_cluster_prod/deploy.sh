#!/bin/bash
# K3s Cluster Deployment Script

set -e

echo "🚀 Starting K3s cluster deployment..."

# Check if terraform is installed
if ! command -v terraform &> /dev/null; then
    echo "❌ Terraform is not installed. Please install Terraform first."
    exit 1
fi

# Check if ansible is installed
if ! command -v ansible-playbook &> /dev/null; then
    echo "❌ Ansible is not installed. Please install Ansible first."
    exit 1
fi

cd "$(dirname "$0")"

echo "📋 Initializing Terraform..."
terraform init

echo "📋 Planning Terraform deployment..."
terraform plan

echo "🔍 Do you want to proceed with the deployment? (y/N)"
read -r response
if [[ ! "$response" =~ ^[Yy]$ ]]; then
    echo "❌ Deployment cancelled."
    exit 0
fi

echo "🚀 Applying Terraform configuration..."
terraform apply -auto-approve

echo "✅ VMs created successfully!"

# Wait a bit for VMs to fully boot
echo "⏳ Waiting for VMs to fully boot..."
sleep 30

echo "🔧 Running Ansible playbook to deploy K3s..."
cd ../ansible
ansible-playbook -i inventories/production/hosts.yml playbooks/k3s-deploy.yml

echo "✅ K3s cluster deployment completed!"
echo ""
echo "📊 To check your cluster status:"
echo "   ssh k3s@172.20.20.101"
echo "   kubectl get nodes -o wide"
echo ""
echo "🔧 To access your cluster from your local machine:"
echo "   scp k3s@172.20.20.101:~/.kube/config ~/.kube/k3s-config"
echo "   export KUBECONFIG=~/.kube/k3s-config"
echo "   kubectl get nodes"
