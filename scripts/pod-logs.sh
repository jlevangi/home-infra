#!/bin/bash

# Kubernetes Pod Logs Fuzzy Finder
# Usage: 
#   ./pod-logs.sh                    # Interactive mode - shows all pods to choose from
#   ./pod-logs.sh -n <name>          # Search for pods containing <name>
#   ./pod-logs.sh -f                 # Follow logs (tail -f equivalent)

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to display help
show_help() {
    echo -e "${BLUE}Kubernetes Pod Logs Fuzzy Finder${NC}"
    echo ""
    echo "Usage:"
    echo "  $0                    # Interactive mode - shows all pods to choose from"
    echo "  $0 -n <name>          # Search for pods containing <name>"
    echo "  $0 -f                 # Follow logs (like tail -f)"
    echo "  $0 -n <name> -f       # Search and follow logs"
    echo "  $0 --lines <number>   # Show last N lines (default: 50)"
    echo "  $0 --namespace <ns>   # Search within specific namespace"
    echo "  $0 --help             # Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 -n vault           # Show logs for pods with 'vault' in the name"
    echo "  $0 -n vault -f        # Follow logs for vault pods"
    echo "  $0 --lines 100        # Show last 100 lines"
    echo ""
}

# Function to get pods with optional filtering (same as pod-describe.sh)
get_pods() {
    local search_term="$1"
    local namespace="$2"
    
    if [[ -n "$namespace" ]]; then
        if [[ -n "$search_term" ]]; then
            kubectl get pods -n "$namespace" --no-headers | grep -i "$search_term" | awk '{print $1 " (" $2 ") [" $3 "] - ns:" ENVIRON["namespace"]}' namespace="$namespace"
        else
            kubectl get pods -n "$namespace" --no-headers | awk '{print $1 " (" $2 ") [" $3 "] - ns:" ENVIRON["namespace"]}' namespace="$namespace"
        fi
    else
        if [[ -n "$search_term" ]]; then
            kubectl get pods -A --no-headers | grep -i "$search_term" | awk '{print $2 " (" $3 ") [" $4 "] - ns:" $1}'
        else
            kubectl get pods -A --no-headers | awk '{print $2 " (" $3 ") [" $4 "] - ns:" $1}'
        fi
    fi
}

# Function to extract pod name and namespace from selection
extract_pod_info() {
    local selection="$1"
    pod_name=$(echo "$selection" | awk '{print $1}')
    namespace=$(echo "$selection" | grep -o 'ns:[^ ]*' | cut -d: -f2)
    echo "$pod_name $namespace"
}

# Function to check if fzf is available
check_fzf() {
    if ! command -v fzf &> /dev/null; then
        echo -e "${YELLOW}Warning: fzf not found. Using basic selection instead.${NC}"
        return 1
    fi
    return 0
}

# Function for interactive selection without fzf
basic_selection() {
    local pods=("$@")
    
    if [[ ${#pods[@]} -eq 0 ]]; then
        echo -e "${RED}No pods found matching criteria.${NC}"
        exit 1
    elif [[ ${#pods[@]} -eq 1 ]]; then
        echo -e "${GREEN}Found one pod: ${pods[0]}${NC}"
        echo "${pods[0]}"
    else
        echo -e "${BLUE}Found ${#pods[@]} pods:${NC}"
        echo ""
        for i in "${!pods[@]}"; do
            echo "  $((i+1)). ${pods[i]}"
        done
        echo ""
        echo -n "Select pod number (1-${#pods[@]}): "
        read -r selection
        
        if [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -ge 1 ]] && [[ "$selection" -le ${#pods[@]} ]]; then
            echo "${pods[$((selection-1))]}"
        else
            echo -e "${RED}Invalid selection.${NC}"
            exit 1
        fi
    fi
}

# Main script logic
main() {
    local search_term=""
    local namespace=""
    local follow=false
    local lines=50
    local use_fzf=true
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -n|--name)
                search_term="$2"
                shift 2
                ;;
            --namespace)
                namespace="$2"
                shift 2
                ;;
            -f|--follow)
                follow=true
                shift
                ;;
            --lines)
                lines="$2"
                shift 2
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            --no-fzf)
                use_fzf=false
                shift
                ;;
            *)
                echo -e "${RED}Unknown option: $1${NC}"
                show_help
                exit 1
                ;;
        esac
    done
    
    # Check if kubectl is available
    if ! command -v kubectl &> /dev/null; then
        echo -e "${RED}Error: kubectl not found. Please install kubectl first.${NC}"
        exit 1
    fi
    
    echo -e "${BLUE}🔍 Searching for pods...${NC}"
    
    # Get pods based on criteria
    if [[ -n "$search_term" ]]; then
        echo -e "Searching for pods containing: ${YELLOW}$search_term${NC}"
    fi
    if [[ -n "$namespace" ]]; then
        echo -e "In namespace: ${YELLOW}$namespace${NC}"
    fi
    echo ""
    
    # Get the list of pods
    pods_output=$(get_pods "$search_term" "$namespace")
    
    if [[ -z "$pods_output" ]]; then
        echo -e "${RED}No pods found matching criteria.${NC}"
        exit 1
    fi
    
    # Convert to array
    readarray -t pods_array <<< "$pods_output"
    
    # Select pod
    if [[ ${#pods_array[@]} -eq 1 ]]; then
        selected_pod="${pods_array[0]}"
        echo -e "${GREEN}Found one pod: $selected_pod${NC}"
    elif $use_fzf && check_fzf; then
        selected_pod=$(printf '%s\n' "${pods_array[@]}" | fzf --prompt="Select pod for logs: " --height=20 --border --header="Use arrow keys to navigate, Enter to select")
        if [[ -z "$selected_pod" ]]; then
            echo -e "${YELLOW}No pod selected.${NC}"
            exit 0
        fi
    else
        selected_pod=$(basic_selection "${pods_array[@]}")
    fi
    
    # Extract pod name and namespace
    read -r pod_name pod_namespace <<< $(extract_pod_info "$selected_pod")
    
    echo ""
    if $follow; then
        echo -e "${GREEN}📜 Following logs for pod: ${YELLOW}$pod_name${GREEN} in namespace: ${YELLOW}$pod_namespace${NC}"
        echo -e "${BLUE}Press Ctrl+C to stop following${NC}"
    else
        echo -e "${GREEN}📜 Showing last $lines lines for pod: ${YELLOW}$pod_name${GREEN} in namespace: ${YELLOW}$pod_namespace${NC}"
    fi
    echo -e "${BLUE}================================${NC}"
    echo ""
    
    # Show logs
    if $follow; then
        kubectl logs "$pod_name" -n "$pod_namespace" -f --tail="$lines"
    else
        kubectl logs "$pod_name" -n "$pod_namespace" --tail="$lines"
    fi
    
    echo ""
    echo -e "${BLUE}================================${NC}"
    echo -e "${GREEN}✅ Logs complete for pod: ${YELLOW}$pod_name${NC}"
}

# Run main function
main "$@"
