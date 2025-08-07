#!/bin/bash
# Generate Kubernetes monitoring token for Telegraf
# This script creates a service account with appropriate permissions for monitoring

echo "🔐 Creating Kubernetes monitoring token for Telegraf..."
echo "=================================================="

# Check if kubectl is available and cluster is accessible
if ! kubectl cluster-info &> /dev/null; then
    echo "❌ Error: kubectl is not available or cluster is not accessible"
    echo "   Make sure you're running this on a K3s master node or have kubeconfig set up"
    exit 1
fi

# Create namespace for monitoring if it doesn't exist
echo "📁 Creating monitoring namespace..."
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

# Create service account
echo "👤 Creating telegraf service account..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: telegraf
  namespace: monitoring
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: telegraf-monitoring
rules:
- apiGroups: [""]
  resources: ["nodes", "nodes/proxy", "nodes/metrics", "services", "endpoints", "pods", "ingresses", "configmaps"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["extensions"]
  resources: ["ingresses"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["apps"]
  resources: ["deployments", "replicasets", "daemonsets", "statefulsets"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["metrics.k8s.io"]
  resources: ["nodes", "pods"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: telegraf-monitoring
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: telegraf-monitoring
subjects:
- kind: ServiceAccount
  name: telegraf
  namespace: monitoring
EOF

# Wait a moment for the service account to be created
sleep 2

# Create a token for the service account (valid for 10 years)
echo "🎫 Generating long-lived token..."
TOKEN=$(kubectl create token telegraf --namespace monitoring --duration=87600h)

if [ -z "$TOKEN" ]; then
    echo "❌ Error: Failed to create token"
    exit 1
fi

echo ""
echo "✅ Telegraf monitoring token created successfully!"
echo ""
echo "🔑 Your monitoring token:"
echo "=================================================="
echo "$TOKEN"
echo "=================================================="
echo ""
echo "📝 Next steps:"
echo "1. Add this token to your Ansible vault:"
echo "   ansible-vault edit ansible/group_vars/k3s_cluster_vault.yml"
echo ""
echo "2. Add this line to your vault file:"
echo "   vault_k3s_monitoring_token: \"$TOKEN\""
echo ""
echo "3. Re-run your Telegraf deployment:"
echo "   ./scripts/deploy_telegraf.sh"
echo ""
echo "🔍 The token grants read-only access to:"
echo "- Node metrics and status"
echo "- Pod metrics and status" 
echo "- Service and endpoint information"
echo "- Deployment and workload status"
echo "- Kubernetes metrics API"
echo ""
echo "🔒 Security: This token has minimal read-only permissions for monitoring only"
