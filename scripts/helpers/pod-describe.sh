#!/bin/bash

# Kubernetes Pod Fuzzy Finder and Describe Tool
# Usage:
#   ./pod-describe.sh                    # Interactive mode - shows all pods to choose from
#   ./pod-describe.sh -n <name>          # Search for pods containing <name>
#   ./pod-describe.sh --help             # Show help

set -e

# Source shared pod utilities
_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_HELPERS_DIR/../lib/pod-utils.sh"

show_help() {
    echo -e "${BLUE}Kubernetes Pod Fuzzy Finder and Describe Tool${NC}"
    echo ""
    echo "Usage:"
    echo "  $0                    # Interactive mode - shows all pods to choose from"
    echo "  $0 -n <name>          # Search for pods containing <name>"
    echo "  $0 --namespace <ns>   # Search within specific namespace"
    echo "  $0 --help             # Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 -n vault           # Find pods with 'vault' in the name"
    echo "  $0 -n book            # Find pods with 'book' in the name"
    echo "  $0 --namespace vaultwarden  # Show pods only in vaultwarden namespace"
    echo ""
}

main() {
    local search_term=""
    local namespace=""
    local use_fzf=true

    while [[ $# -gt 0 ]]; do
        case $1 in
            -n|--name)     search_term="$2"; shift 2 ;;
            --namespace)   namespace="$2"; shift 2 ;;
            --help|-h)     show_help; exit 0 ;;
            --no-fzf)      use_fzf=false; shift ;;
            *)             echo -e "${RED}Unknown option: $1${NC}"; show_help; exit 1 ;;
        esac
    done

    local selected_pod
    selected_pod=$(select_pod "$search_term" "$namespace" "$use_fzf" "Select pod to describe: ")

    read -r pod_name pod_namespace <<< $(extract_pod_info "$selected_pod")

    echo ""
    echo -e "${GREEN}📋 Describing pod: ${YELLOW}$pod_name${GREEN} in namespace: ${YELLOW}$pod_namespace${NC}"
    echo -e "${BLUE}================================${NC}"
    echo ""

    kubectl describe pod "$pod_name" -n "$pod_namespace"

    echo ""
    echo -e "${BLUE}================================${NC}"
    echo -e "${GREEN}✅ Description complete for pod: ${YELLOW}$pod_name${NC}"
    echo ""
    echo -e "${BLUE}💡 Useful follow-up commands:${NC}"
    echo "  kubectl logs $pod_name -n $pod_namespace"
    echo "  kubectl exec -it $pod_name -n $pod_namespace -- sh"
    echo "  kubectl get pod $pod_name -n $pod_namespace -o yaml"
}

main "$@"
