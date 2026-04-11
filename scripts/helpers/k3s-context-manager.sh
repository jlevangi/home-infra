#!/bin/bash
# k3s-context-manager.sh
# Unified script to manage multiple K3s clusters with proper contexts

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
# SSH user must match the cloud-init user provisioned on the VMs (see
# terraform/<cluster>/terraform.tfvars `ci_user`, default `ansible`). The
# matching private key is discovered via your ~/.ssh/config or ssh-agent.
CLUSTERS=(
    "prod:172.20.20.101:ansible"
    "stage:172.20.20.111:ansible"
    "test:172.20.20.121:ansible"
)

LOCAL_KUBECONFIG_DIR="$HOME/.kube"
MASTER_KUBECONFIG="$LOCAL_KUBECONFIG_DIR/config"
REMOTE_KUBECONFIG="/etc/rancher/k3s/k3s.yaml"

# Create .kube directory if it doesn't exist
mkdir -p "$LOCAL_KUBECONFIG_DIR"

function show_usage() {
    echo "Usage: $0 [setup|switch|list|status|cleanup]"
    echo ""
    echo "Commands:"
    echo "  setup       - Setup kubeconfigs for all clusters"
    echo "  switch      - Switch between cluster contexts"
    echo "  list        - List available contexts"
    echo "  status      - Show current context and cluster info"
    echo "  cleanup     - Clean up SSH known_hosts for all cluster nodes"
    echo ""
    echo "Available clusters: prod, stage, test"
}

function cleanup_known_hosts() {
    local master_node="$1"
    local cluster_name="$2"
    
    # Check if known_hosts file exists
    if [ ! -f "$HOME/.ssh/known_hosts" ]; then
        return 0
    fi
    
    # Check if the host exists in known_hosts (check for any lines containing the IP)
    if grep -q "$master_node" "$HOME/.ssh/known_hosts" 2>/dev/null; then
        echo -e "${YELLOW}🧹 Cleaning up old SSH host key for $master_node ($cluster_name)...${NC}"
        
        # Remove all entries for this host (handles different key types)
        ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$master_node" > /dev/null 2>&1
        
        # Also try to remove any entries that might be in [ip]:port format
        ssh-keygen -f "$HOME/.ssh/known_hosts" -R "[$master_node]:22" > /dev/null 2>&1
        
        # Double-check and manually remove any remaining entries
        if grep -q "$master_node" "$HOME/.ssh/known_hosts" 2>/dev/null; then
            echo -e "${YELLOW}🔧 Manually removing remaining entries...${NC}"
            sed -i "/$master_node/d" "$HOME/.ssh/known_hosts" 2>/dev/null || true
        fi
        
        echo -e "${GREEN}✅ SSH host key cleaned up for $master_node${NC}"
    fi
}

function test_connectivity() {
    local cluster_name="$1"
    local master_node="$2"
    local master_user="$3"
    
    echo -e "${YELLOW}📡 Testing connectivity to $cluster_name cluster ($master_node)...${NC}"
    
    if ! ping -c 1 "$master_node" > /dev/null 2>&1; then
        echo -e "${RED}❌ Cannot reach master node at $master_node${NC}"
        return 1
    fi
    
    # Clean up old SSH host keys before attempting connection
    cleanup_known_hosts "$master_node" "$cluster_name"
    
    if ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$master_user@$master_node" "echo 'SSH connection successful'" > /dev/null 2>&1; then
        echo -e "${RED}❌ Cannot SSH to master node${NC}"
        return 1
    fi
    
    if ! ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$master_user@$master_node" "systemctl is-active k3s" > /dev/null 2>&1; then
        echo -e "${RED}❌ K3s service is not running on master node${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✅ Connectivity test passed for $cluster_name cluster${NC}"
    return 0
}

function setup_cluster() {
    local cluster_name="$1"
    local master_node="$2"
    local master_user="$3"
    
    echo -e "${BLUE}🔧 Setting up kubeconfig for $cluster_name cluster...${NC}"
    
    # Test connectivity first (disable exit on error temporarily)
    set +e
    if ! test_connectivity "$cluster_name" "$master_node" "$master_user"; then
        echo -e "${RED}❌ Skipping $cluster_name cluster due to connectivity issues${NC}"
        set -e
        return 1
    fi
    set -e
    
    # Create temporary kubeconfig file
    local temp_config="/tmp/k3s-$cluster_name-config"
    
    # Download kubeconfig
    echo -e "${YELLOW}📥 Downloading kubeconfig from $cluster_name cluster...${NC}"
    if ! scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$master_user@$master_node:$REMOTE_KUBECONFIG" "$temp_config"; then
        echo -e "${RED}❌ Failed to download kubeconfig for $cluster_name${NC}"
        return 1
    fi
    
    # Update server address and context names
    echo -e "${YELLOW}🔧 Configuring context for $cluster_name cluster...${NC}"
    sed -i "s/127.0.0.1/$master_node/g" "$temp_config"
    sed -i "s/name: default/name: k3s-$cluster_name/g" "$temp_config"
    sed -i "s/cluster: default/cluster: k3s-$cluster_name/g" "$temp_config"
    sed -i "s/user: default/user: k3s-$cluster_name/g" "$temp_config"
    sed -i "s/current-context: default/current-context: k3s-$cluster_name/g" "$temp_config"
    
    # Merge with existing kubeconfig manually to avoid kubectl corruption
    if [ -f "$MASTER_KUBECONFIG" ]; then
        echo -e "${YELLOW}🔀 Merging with existing kubeconfig...${NC}"
        
        # Create backup
        cp "$MASTER_KUBECONFIG" "$MASTER_KUBECONFIG.backup"
        
        # Check if this cluster context already exists
        if grep -q "name: k3s-$cluster_name" "$MASTER_KUBECONFIG"; then
            echo -e "${YELLOW}🔄 Updating existing k3s-$cluster_name context...${NC}"
            # Remove existing entries for this cluster
            # Create a temporary Python script to avoid shell variable expansion issues
            cat > "/tmp/merge_kubeconfig.py" << 'EOF'
import yaml
import sys

cluster_name = sys.argv[1]
master_config = sys.argv[2] 
temp_config = sys.argv[3]

# Read master config
with open(master_config, 'r') as f:
    master = yaml.safe_load(f)

# Read new config  
with open(temp_config, 'r') as f:
    new = yaml.safe_load(f)

# Remove existing cluster entries
master['clusters'] = [c for c in master.get('clusters', []) if c['name'] != f'k3s-{cluster_name}']
master['users'] = [u for u in master.get('users', []) if u['name'] != f'k3s-{cluster_name}']  
master['contexts'] = [c for c in master.get('contexts', []) if c['name'] != f'k3s-{cluster_name}']

# Add new entries
master['clusters'].extend(new.get('clusters', []))
master['users'].extend(new.get('users', []))
master['contexts'].extend(new.get('contexts', []))

# Write back
with open(master_config, 'w') as f:
    yaml.dump(master, f, default_flow_style=False)
EOF
            if python3 /tmp/merge_kubeconfig.py "$cluster_name" "$MASTER_KUBECONFIG" "$temp_config" 2>/dev/null; then
                echo -e "${GREEN}✅ Successfully merged using Python YAML${NC}"
            else
                echo -e "${YELLOW}⚠️ Python yaml not available, using kubectl merge${NC}"
                # Use kubectl to properly merge configs instead of simple append
                export KUBECONFIG="$MASTER_KUBECONFIG:$temp_config"
                kubectl config view --flatten > "/tmp/merged_config"
                mv "/tmp/merged_config" "$MASTER_KUBECONFIG"
                unset KUBECONFIG
            fi
        else
            echo -e "${YELLOW}➕ Adding new k3s-$cluster_name context...${NC}"
            # Use kubectl to properly merge configs instead of simple append
            export KUBECONFIG="$MASTER_KUBECONFIG:$temp_config"
            kubectl config view --flatten > "/tmp/merged_config"
            mv "/tmp/merged_config" "$MASTER_KUBECONFIG"
            unset KUBECONFIG
        fi
    else
        echo -e "${YELLOW}📄 Creating new kubeconfig...${NC}"
        cp "$temp_config" "$MASTER_KUBECONFIG"
    fi
    
    # Clean up temporary file
    rm "$temp_config"
    
    # Set appropriate permissions
    chmod 600 "$MASTER_KUBECONFIG"
    
    echo -e "${GREEN}✅ Successfully configured $cluster_name cluster${NC}"
    return 0
}

function setup_all_clusters() {
    echo -e "${BLUE}🚀 Setting up kubeconfigs for all K3s clusters...${NC}"
    
    local success_count=0
    local total_count=${#CLUSTERS[@]}
    
    for cluster_config in "${CLUSTERS[@]}"; do
        IFS=':' read -r cluster_name master_node master_user <<< "$cluster_config"
        
        echo -e "${YELLOW}Processing cluster: $cluster_name ($master_node)${NC}"
        if setup_cluster "$cluster_name" "$master_node" "$master_user"; then
            success_count=$((success_count + 1))
        else
            echo -e "${RED}❌ Failed to setup $cluster_name cluster${NC}"
        fi
        echo ""
    done
    
    if [ $success_count -eq $total_count ]; then
        echo -e "${GREEN}🎉 All clusters configured successfully!${NC}"
        
        # Set default context to prod if available
        if kubectl config get-contexts k3s-prod > /dev/null 2>&1; then
            kubectl config use-context k3s-prod
            echo -e "${GREEN}✅ Default context set to k3s-prod${NC}"
        fi
        
        list_contexts
    else
        echo -e "${YELLOW}⚠️ Successfully configured $success_count out of $total_count clusters${NC}"
    fi
}

function switch_context() {
    if [ -z "$1" ]; then
        echo "Available clusters:"
        for cluster_config in "${CLUSTERS[@]}"; do
            IFS=':' read -r cluster_name master_node master_user <<< "$cluster_config"
            echo "  $cluster_name"
        done
        echo ""
        read -p "Enter cluster name to switch to: " cluster_choice
    else
        cluster_choice="$1"
    fi
    
    local context_name="k3s-$cluster_choice"
    
    if kubectl config get-contexts "$context_name" > /dev/null 2>&1; then
        kubectl config use-context "$context_name"
        echo -e "${GREEN}✅ Switched to $cluster_choice cluster${NC}"
        show_status
    else
        echo -e "${RED}❌ Context $context_name not found${NC}"
        echo -e "${YELLOW}💡 Run '$0 setup' first to configure all clusters${NC}"
        return 1
    fi
}

function list_contexts() {
    echo -e "${BLUE}📋 Available Kubernetes contexts:${NC}"
    kubectl config get-contexts
}

function show_status() {
    echo -e "${BLUE}📊 Current Cluster Status:${NC}"
    echo -e "${YELLOW}Current context:${NC} $(kubectl config current-context)"
    echo ""
    
    if timeout 5 kubectl cluster-info > /dev/null 2>&1; then
        echo -e "${GREEN}✅ Cluster is reachable${NC}"
        timeout 10 kubectl get nodes -o wide
    else
        echo -e "${RED}❌ Cannot connect to cluster (timeout after 5s)${NC}"
    fi
}

function cleanup_all_known_hosts() {
    echo -e "${BLUE}🧹 Cleaning up SSH known_hosts for all cluster nodes...${NC}"
    
    local cleaned_count=0
    
    for cluster_config in "${CLUSTERS[@]}"; do
        IFS=':' read -r cluster_name master_node master_user <<< "$cluster_config"
        
        echo -e "${YELLOW}Processing $cluster_name cluster ($master_node)...${NC}"
        cleanup_known_hosts "$master_node" "$cluster_name"
        cleaned_count=$((cleaned_count + 1))
    done
    
    echo ""
    echo -e "${GREEN}✅ Cleaned up SSH host keys for $cleaned_count cluster(s)${NC}"
    echo -e "${YELLOW}💡 You can now run './scripts/helpers/k3s-context-manager.sh setup' to reconnect to clusters${NC}"
}

# Main script logic
case "${1:-}" in
    "setup")
        setup_all_clusters
        ;;
    "switch")
        switch_context "$2"
        ;;
    "list")
        list_contexts
        ;;
    "status")
        show_status
        ;;
    "cleanup")
        cleanup_all_known_hosts
        ;;
    "")
        show_usage
        ;;
    *)
        echo -e "${RED}❌ Unknown command: $1${NC}"
        show_usage
        exit 1
        ;;
esac
