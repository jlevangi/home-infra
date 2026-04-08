#!/bin/bash

# Kubernetes Pod Logs Fuzzy Finder
# Usage:
#   ./pod-logs.sh                    # Interactive mode - shows all pods to choose from
#   ./pod-logs.sh -n <name>          # Search for pods containing <name>
#   ./pod-logs.sh -f                 # Follow logs (tail -f equivalent)

set -e

# Source shared pod utilities
_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_HELPERS_DIR/../lib/pod-utils.sh"

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

main() {
    local search_term=""
    local namespace=""
    local follow=false
    local lines=50
    local use_fzf=true

    while [[ $# -gt 0 ]]; do
        case $1 in
            -n|--name)     search_term="$2"; shift 2 ;;
            --namespace)   namespace="$2"; shift 2 ;;
            -f|--follow)   follow=true; shift ;;
            --lines)       lines="$2"; shift 2 ;;
            --help|-h)     show_help; exit 0 ;;
            --no-fzf)      use_fzf=false; shift ;;
            *)             echo -e "${RED}Unknown option: $1${NC}"; show_help; exit 1 ;;
        esac
    done

    local selected_pod
    selected_pod=$(select_pod "$search_term" "$namespace" "$use_fzf" "Select pod for logs: ")

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

    if $follow; then
        kubectl logs "$pod_name" -n "$pod_namespace" -f --tail="$lines"
    else
        kubectl logs "$pod_name" -n "$pod_namespace" --tail="$lines"
    fi

    echo ""
    echo -e "${BLUE}================================${NC}"
    echo -e "${GREEN}✅ Logs complete for pod: ${YELLOW}$pod_name${NC}"
}

main "$@"
