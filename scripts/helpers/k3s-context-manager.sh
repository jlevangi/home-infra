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
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PROJECT_ROOT="$(cd "$_SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/environment-functions.sh
source "$_PROJECT_ROOT/scripts/lib/environment-functions.sh"
require_ansible_config

CLUSTERS=(
    "prod"
    "stage"
    "test"
)

get_inventory_dir() {
    local cluster_name="$1"

    case "$cluster_name" in
        prod)  echo "production" ;;
        stage) echo "staging" ;;
        *)     echo "$cluster_name" ;;
    esac
}

get_master_group() {
    local cluster_name="$1"
    echo "k3s_cluster_${cluster_name}_master"
}

get_master_node() {
    local cluster_name="$1"
    local inv_dir
    inv_dir=$(get_inventory_dir "$cluster_name")
    local inv_file="$_PROJECT_ROOT/ansible/inventories/$inv_dir/hosts.yml"
    local master_group
    master_group=$(get_master_group "$cluster_name")

    if [ ! -f "$inv_file" ]; then
        echo ""
        return 1
    fi

    python3 - "$inv_file" "$master_group" <<'PY'
import sys

inventory_path, master_group = sys.argv[1], sys.argv[2]

with open(inventory_path, "r", encoding="utf-8") as fh:
    lines = fh.readlines()

in_group = False
in_hosts = False
group_indent = None
hosts_indent = None

for raw_line in lines:
    line = raw_line.rstrip("\n")
    stripped = line.strip()

    if not stripped or stripped.startswith("#"):
        continue

    indent = len(raw_line) - len(raw_line.lstrip(" "))

    if stripped == f"{master_group}:":
        in_group = True
        in_hosts = False
        group_indent = indent
        hosts_indent = None
        continue

    if in_group and indent <= group_indent and stripped.endswith(":"):
        in_group = False
        in_hosts = False

    if not in_group:
        continue

    if stripped == "hosts:":
        in_hosts = True
        hosts_indent = indent
        continue

    if in_hosts and indent <= hosts_indent and stripped.endswith(":"):
        continue

    if in_hosts and stripped.startswith("ansible_host:"):
        print(stripped.split(":", 1)[1].strip())
        sys.exit(0)

sys.exit(1)
PY
}

get_master_nodes() {
    local cluster_name="$1"
    local inv_dir
    inv_dir=$(get_inventory_dir "$cluster_name")
    local inv_file="$_PROJECT_ROOT/ansible/inventories/$inv_dir/hosts.yml"
    local master_group
    master_group=$(get_master_group "$cluster_name")

    if [ ! -f "$inv_file" ]; then
        return 1
    fi

    python3 - "$inv_file" "$master_group" <<'PY'
import sys

inventory_path, master_group = sys.argv[1], sys.argv[2]

with open(inventory_path, "r", encoding="utf-8") as fh:
    lines = fh.readlines()

in_group = False
in_hosts = False
group_indent = None
hosts_indent = None

for raw_line in lines:
    line = raw_line.rstrip("\n")
    stripped = line.strip()

    if not stripped or stripped.startswith("#"):
        continue

    indent = len(raw_line) - len(raw_line.lstrip(" "))

    if stripped == f"{master_group}:":
        in_group = True
        in_hosts = False
        group_indent = indent
        hosts_indent = None
        continue

    if in_group and indent <= group_indent and stripped.endswith(":"):
        in_group = False
        in_hosts = False

    if not in_group:
        continue

    if stripped == "hosts:":
        in_hosts = True
        hosts_indent = indent
        continue

    if in_hosts and indent <= hosts_indent and stripped.endswith(":"):
        continue

    if in_hosts and stripped.startswith("ansible_host:"):
        print(stripped.split(":", 1)[1].strip())
PY
}

get_api_endpoint() {
    local cluster_name="$1"
    local group_vars_file="$_PROJECT_ROOT/ansible/group_vars/k3s_cluster_${cluster_name}.yml"

    if [ ! -f "$group_vars_file" ]; then
        echo ""
        return 0
    fi

    python3 - "$group_vars_file" <<'PY'
import sys
import yaml

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    data = yaml.safe_load(fh) or {}

value = data.get("k3s_api_endpoint", "")
print(value if isinstance(value, str) else "")
PY
}

# Derive the SSH user for a given cluster by mirroring Ansible's own
# precedence: inventory ansible_user overrides ansible.cfg remote_user.
get_ssh_user() {
    local cluster_name="$1"
    local cfg="$_PROJECT_ROOT/ansible/ansible.cfg"

    # Map short cluster name to inventory directory
    local inv_dir
    inv_dir=$(get_inventory_dir "$cluster_name")

    local inv_file="$_PROJECT_ROOT/ansible/inventories/$inv_dir/hosts.yml"

    # Check for ansible_user override in the inventory
    if [ -f "$inv_file" ]; then
        local inv_user
        inv_user=$(grep -m1 'ansible_user:' "$inv_file" 2>/dev/null | awk '{print $2}' | tr -d "\"'")
        if [ -n "$inv_user" ]; then
            echo "$inv_user"
            return
        fi
    fi

    # Fall back to remote_user from ansible.cfg
    if [ -f "$cfg" ]; then
        local cfg_user
        cfg_user=$(grep -m1 '^remote_user' "$cfg" 2>/dev/null | awk '{print $3}' | tr -d "\"'")
        if [ -n "$cfg_user" ]; then
            echo "$cfg_user"
            return
        fi
    fi

    # Ultimate fallback
    echo "ansible"
}

expand_path() {
    local path="$1"

    case "$path" in
        "~")
            path="$HOME"
            ;;
        "~/"*)
            path="$HOME/${path#\~/}"
            ;;
    esac

    if [ -e "$path" ]; then
        readlink -f "$path"
    else
        printf '%s\n' "$path"
    fi
}

get_ssh_private_key() {
    local cluster_name="$1"
    local cfg="$_PROJECT_ROOT/ansible/ansible.cfg"

    local inv_dir
    inv_dir=$(get_inventory_dir "$cluster_name")

    local inv_file="$_PROJECT_ROOT/ansible/inventories/$inv_dir/hosts.yml"

    if [ -f "$inv_file" ]; then
        local inv_key
        inv_key=$(grep -m1 'ansible_ssh_private_key_file:' "$inv_file" 2>/dev/null | awk '{print $2}' | tr -d "\"'")
        if [ -n "$inv_key" ]; then
            expand_path "$inv_key"
            return
        fi
    fi

    if [ -f "$cfg" ]; then
        local cfg_key
        cfg_key=$(grep -m1 '^private_key_file' "$cfg" 2>/dev/null | awk '{print $3}' | tr -d "\"'")
        if [ -n "$cfg_key" ]; then
            expand_path "$cfg_key"
            return
        fi
    fi
}

build_ssh_opts() {
    local cluster_name="$1"
    local ssh_key
    ssh_key=$(get_ssh_private_key "$cluster_name")

    local -a ssh_opts=(
        -F /dev/null
        -o ConnectTimeout=5
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        -o LogLevel=ERROR
    )

    if [ -n "$ssh_key" ]; then
        ssh_opts+=(-i "$ssh_key")
    fi

    printf '%s\n' "${ssh_opts[@]}"
}

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
    local -a ssh_opts=()

    mapfile -t ssh_opts < <(build_ssh_opts "$cluster_name")
    
    echo -e "${YELLOW}📡 Testing connectivity to $cluster_name cluster ($master_node)...${NC}"
    
    if ! ping -c 1 "$master_node" > /dev/null 2>&1; then
        echo -e "${RED}❌ Cannot reach master node at $master_node${NC}"
        return 1
    fi
    
    # Clean up old SSH host keys before attempting connection
    cleanup_known_hosts "$master_node" "$cluster_name"
    
    if ! ssh "${ssh_opts[@]}" "$master_user@$master_node" "echo 'SSH connection successful'" > /dev/null 2>&1; then
        echo -e "${RED}❌ Cannot SSH to master node${NC}"
        return 1
    fi
    
    if ! ssh "${ssh_opts[@]}" "$master_user@$master_node" "systemctl is-active k3s" > /dev/null 2>&1; then
        echo -e "${RED}❌ K3s service is not running on master node${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✅ Connectivity test passed for $cluster_name cluster${NC}"
    return 0
}

function setup_cluster() {
    local cluster_name="$1"
    local source_node="$2"
    local master_user="$3"
    local api_endpoint="$4"
    local -a ssh_opts=()

    mapfile -t ssh_opts < <(build_ssh_opts "$cluster_name")
    
    echo -e "${BLUE}🔧 Setting up kubeconfig for $cluster_name cluster...${NC}"
    
    # Test connectivity first (disable exit on error temporarily)
    set +e
    if ! test_connectivity "$cluster_name" "$source_node" "$master_user"; then
        echo -e "${RED}❌ Skipping $cluster_name cluster due to connectivity issues${NC}"
        set -e
        return 1
    fi
    set -e
    
    # Create temporary kubeconfig file
    local temp_config="/tmp/k3s-$cluster_name-config"
    
    # Download kubeconfig
    echo -e "${YELLOW}📥 Downloading kubeconfig from $cluster_name cluster...${NC}"
    if ! scp "${ssh_opts[@]}" "$master_user@$source_node:$REMOTE_KUBECONFIG" "$temp_config"; then
        echo -e "${RED}❌ Failed to download kubeconfig for $cluster_name${NC}"
        return 1
    fi
    
    # Update server address and context names
    echo -e "${YELLOW}🔧 Configuring context for $cluster_name cluster...${NC}"
    local kubeconfig_endpoint="$source_node"
    if [ -n "$api_endpoint" ]; then
        kubeconfig_endpoint="$api_endpoint"
    fi
    sed -i "s/127.0.0.1/$kubeconfig_endpoint/g" "$temp_config"
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
    
    for cluster_name in "${CLUSTERS[@]}"; do
        local master_nodes
        mapfile -t master_nodes < <(get_master_nodes "$cluster_name")
        if [ ${#master_nodes[@]} -eq 0 ]; then
            echo -e "${RED}❌ Could not determine control-plane IP for $cluster_name from inventory${NC}"
            echo ""
            continue
        fi

        local source_node=""
        local candidate
        for candidate in "${master_nodes[@]}"; do
            if ping -c 1 "$candidate" > /dev/null 2>&1; then
                source_node="$candidate"
                break
            fi
        done
        if [ -z "$source_node" ]; then
            source_node="${master_nodes[0]}"
        fi
        local master_user
        master_user=$(get_ssh_user "$cluster_name")
        local api_endpoint
        api_endpoint=$(get_api_endpoint "$cluster_name")

        echo -e "${YELLOW}Processing cluster: $cluster_name ($source_node)${NC}"
        if setup_cluster "$cluster_name" "$source_node" "$master_user" "$api_endpoint"; then
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
        for cluster_name in "${CLUSTERS[@]}"; do
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
    
    for cluster_name in "${CLUSTERS[@]}"; do
        local master_node
        master_node=$(get_master_node "$cluster_name")
        if [ -z "$master_node" ]; then
            echo -e "${RED}❌ Could not determine control-plane IP for $cluster_name from inventory${NC}"
            continue
        fi

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
