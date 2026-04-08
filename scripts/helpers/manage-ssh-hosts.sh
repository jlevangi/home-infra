#!/bin/bash

# SSH Known Hosts Management Script for K3s Clusters
# This script helps manage SSH known hosts when clusters are rebuilt

set -euo pipefail

# Color codes for output (check if terminal supports colors)
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && tput colors >/dev/null 2>&1 && [[ $(tput colors) -ge 8 ]]; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    BLUE=$(tput setaf 4)
    NC=$(tput sgr0) # No Color
else
    # Fallback to no colors if terminal doesn't support them
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

# Cluster IP configurations
declare -A CLUSTER_IPS=(
    ["prod"]="172.20.20.101 172.20.20.102 172.20.20.103"
    ["test"]="172.20.20.121 172.20.20.122 172.20.20.123"  
    ["stage"]="172.20.20.111 172.20.20.112 172.20.20.113"
)

# Cluster hostnames (optional - if you use hostnames in addition to IPs)
declare -A CLUSTER_HOSTNAMES=(
    ["prod"]="k3s-prod-node-1 k3s-prod-node-2 k3s-prod-node-3"
    ["test"]="k3s-test-node-1 k3s-test-node-2 k3s-test-node-3"
    ["stage"]="k3s-stage-node-1 k3s-stage-node-2 k3s-stage-node-3"
)

# SSH known_hosts file location
KNOWN_HOSTS_FILE="${HOME}/.ssh/known_hosts"

# Backup known_hosts before making changes
backup_known_hosts() {
    if [[ -f "$KNOWN_HOSTS_FILE" ]]; then
        local backup_file="${KNOWN_HOSTS_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$KNOWN_HOSTS_FILE" "$backup_file"
        echo -e "${GREEN}✅ Backed up known_hosts to: $backup_file${NC}"
    fi
}

# Remove SSH known hosts for a cluster
remove_cluster_hosts() {
    local cluster="$1"
    
    if [[ ! -v CLUSTER_IPS[$cluster] ]]; then
        echo -e "${RED}❌ Unknown cluster: $cluster${NC}"
        echo -e "${YELLOW}Available clusters: ${!CLUSTER_IPS[*]}${NC}"
        return 1
    fi
    
    echo -e "${BLUE}🔄 Removing SSH known hosts for $cluster cluster...${NC}"
    
    # Remove by IP addresses
    for ip in ${CLUSTER_IPS[$cluster]}; do
        if ssh-keygen -R "$ip" 2>/dev/null; then
            echo -e "${GREEN}  ✅ Removed $ip${NC}"
        else
            echo -e "${YELLOW}  ⚠️  No entry found for $ip${NC}"
        fi
    done
    
    # Remove by hostnames (if they exist in known_hosts)
    for hostname in ${CLUSTER_HOSTNAMES[$cluster]}; do
        if ssh-keygen -R "$hostname" 2>/dev/null; then
            echo -e "${GREEN}  ✅ Removed $hostname${NC}"
        else
            echo -e "${YELLOW}  ⚠️  No entry found for $hostname${NC}"
        fi
    done
    
    echo -e "${GREEN}✅ Completed removal for $cluster cluster${NC}"
}

# Add SSH known hosts for a cluster
add_cluster_hosts() {
    local cluster="$1"
    
    if [[ ! -v CLUSTER_IPS[$cluster] ]]; then
        echo -e "${RED}❌ Unknown cluster: $cluster${NC}"
        echo -e "${YELLOW}Available clusters: ${!CLUSTER_IPS[*]}${NC}"
        return 1
    fi
    
    echo -e "${BLUE}🔄 Adding SSH known hosts for $cluster cluster...${NC}"
    
    local success_count=0
    local total_count=0
    
    # Add by IP addresses
    for ip in ${CLUSTER_IPS[$cluster]}; do
        ((total_count++))
        echo -e "${BLUE}  🔍 Connecting to $ip to get host key...${NC}"
        
        if ssh-keyscan -H "$ip" >> "$KNOWN_HOSTS_FILE" 2>/dev/null; then
            echo -e "${GREEN}  ✅ Added $ip${NC}"
            ((success_count++))
        else
            echo -e "${RED}  ❌ Failed to get host key from $ip (host may be down)${NC}"
        fi
    done
    
    echo -e "${GREEN}✅ Added $success_count/$total_count host keys for $cluster cluster${NC}"
    
    if [[ $success_count -lt $total_count ]]; then
        echo -e "${YELLOW}⚠️  Some hosts were unreachable. You may need to add them later when they're online.${NC}"
    fi
}

# Refresh (remove and re-add) cluster hosts
refresh_cluster_hosts() {
    local cluster="$1"
    
    echo -e "${BLUE}🔄 Refreshing SSH known hosts for $cluster cluster...${NC}"
    remove_cluster_hosts "$cluster"
    echo ""
    add_cluster_hosts "$cluster"
}

# Remove all cluster hosts
remove_all_hosts() {
    echo -e "${BLUE}🔄 Removing SSH known hosts for ALL clusters...${NC}"
    for cluster in "${!CLUSTER_IPS[@]}"; do
        echo -e "\n${YELLOW}--- Processing $cluster cluster ---${NC}"
        remove_cluster_hosts "$cluster"
    done
    echo -e "\n${GREEN}✅ Completed removal for all clusters${NC}"
}

# Add all cluster hosts
add_all_hosts() {
    echo -e "${BLUE}🔄 Adding SSH known hosts for ALL clusters...${NC}"
    for cluster in "${!CLUSTER_IPS[@]}"; do
        echo -e "\n${YELLOW}--- Processing $cluster cluster ---${NC}"
        add_cluster_hosts "$cluster"
    done
    echo -e "\n${GREEN}✅ Completed adding hosts for all clusters${NC}"
}

# Refresh all cluster hosts
refresh_all_hosts() {
    echo -e "${BLUE}🔄 Refreshing SSH known hosts for ALL clusters...${NC}"
    for cluster in "${!CLUSTER_IPS[@]}"; do
        echo -e "\n${YELLOW}--- Processing $cluster cluster ---${NC}"
        refresh_cluster_hosts "$cluster"
    done
    echo -e "\n${GREEN}✅ Completed refresh for all clusters${NC}"
}

# List current known hosts for clusters
list_cluster_hosts() {
    echo -e "${BLUE}📋 Current SSH known hosts for K3s clusters:${NC}\n"
    
    if [[ ! -f "$KNOWN_HOSTS_FILE" ]]; then
        echo -e "${YELLOW}⚠️  No known_hosts file found at $KNOWN_HOSTS_FILE${NC}"
        return
    fi
    
    for cluster in "${!CLUSTER_IPS[@]}"; do
        echo -e "${YELLOW}--- $cluster cluster ---${NC}"
        local found_any=false
        
        # Check IPs
        for ip in ${CLUSTER_IPS[$cluster]}; do
            if grep -q "^$ip\|^|1|$ip" "$KNOWN_HOSTS_FILE" 2>/dev/null; then
                echo -e "${GREEN}  ✅ $ip${NC}"
                found_any=true
            else
                echo -e "${RED}  ❌ $ip (not found)${NC}"
            fi
        done
        
        # Check hostnames
        for hostname in ${CLUSTER_HOSTNAMES[$cluster]}; do
            if grep -q "$hostname" "$KNOWN_HOSTS_FILE" 2>/dev/null; then
                echo -e "${GREEN}  ✅ $hostname${NC}"
                found_any=true
            fi
        done
        
        if [[ "$found_any" == false ]]; then
            echo -e "${RED}  ❌ No entries found for $cluster cluster${NC}"
        fi
        echo ""
    done
}

# Show usage information
show_usage() {
    cat << EOF
${BLUE}SSH Known Hosts Management Script for K3s Clusters${NC}

${YELLOW}Usage:${NC}
  $0 <command> [cluster]

${YELLOW}Commands:${NC}
  ${GREEN}remove <cluster>${NC}     - Remove SSH known hosts for specific cluster
  ${GREEN}add <cluster>${NC}        - Add SSH known hosts for specific cluster  
  ${GREEN}refresh <cluster>${NC}    - Remove and re-add SSH known hosts for specific cluster
  ${GREEN}remove-all${NC}           - Remove SSH known hosts for ALL clusters
  ${GREEN}add-all${NC}              - Add SSH known hosts for ALL clusters
  ${GREEN}refresh-all${NC}          - Refresh SSH known hosts for ALL clusters
  ${GREEN}list${NC}                 - List current SSH known hosts for clusters
  ${GREEN}help${NC}                 - Show this usage information

${YELLOW}Available Clusters:${NC}
  ${GREEN}prod${NC}    - Production cluster (172.20.20.101-103)
  ${GREEN}test${NC}    - Test cluster (172.20.20.121-123)
  ${GREEN}stage${NC}   - Staging cluster (172.20.20.111-113)

${YELLOW}Examples:${NC}
  $0 refresh stage          # Refresh staging cluster hosts after rebuild
  $0 remove-all             # Remove all cluster hosts before mass rebuild
  $0 add-all                # Re-add all cluster hosts after rebuilds
  $0 list                   # Show current status of known hosts

${YELLOW}Notes:${NC}
  - A backup of known_hosts is created before any modifications
  - Use 'refresh' after rebuilding a cluster with new host keys
  - Use 'remove-all' before rebuilding multiple clusters
  - Use 'add-all' to re-scan all hosts after rebuilds

EOF
}

# Main script logic
main() {
    # Check if ssh-keygen is available
    if ! command -v ssh-keygen &> /dev/null; then
        echo -e "${RED}❌ ssh-keygen command not found. Please install OpenSSH client.${NC}"
        exit 1
    fi
    
    # Create backup before any modifications
    if [[ $# -gt 0 && "$1" != "list" && "$1" != "help" ]]; then
        backup_known_hosts
        echo ""
    fi
    
    # Process commands
    case "${1:-help}" in
        "remove")
            if [[ $# -lt 2 ]]; then
                echo -e "${RED}❌ Cluster name required${NC}"
                echo -e "${YELLOW}Usage: $0 remove <cluster>${NC}"
                echo -e "${YELLOW}Available clusters: ${!CLUSTER_IPS[*]}${NC}"
                exit 1
            fi
            remove_cluster_hosts "$2"
            ;;
        "add")
            if [[ $# -lt 2 ]]; then
                echo -e "${RED}❌ Cluster name required${NC}"
                echo -e "${YELLOW}Usage: $0 add <cluster>${NC}"
                echo -e "${YELLOW}Available clusters: ${!CLUSTER_IPS[*]}${NC}"
                exit 1
            fi
            add_cluster_hosts "$2"
            ;;
        "refresh")
            if [[ $# -lt 2 ]]; then
                echo -e "${RED}❌ Cluster name required${NC}"
                echo -e "${YELLOW}Usage: $0 refresh <cluster>${NC}"
                echo -e "${YELLOW}Available clusters: ${!CLUSTER_IPS[*]}${NC}"
                exit 1
            fi
            refresh_cluster_hosts "$2"
            ;;
        "remove-all")
            remove_all_hosts
            ;;
        "add-all")
            add_all_hosts
            ;;
        "refresh-all")
            refresh_all_hosts
            ;;
        "list")
            list_cluster_hosts
            ;;
        "help"|"-h"|"--help")
            show_usage
            ;;
        *)
            echo -e "${RED}❌ Unknown command: $1${NC}\n"
            show_usage
            exit 1
            ;;
    esac
}

# Run the main function with all arguments
main "$@"