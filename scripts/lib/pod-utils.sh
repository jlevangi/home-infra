#!/bin/bash
# Shared pod selection utilities for pod-describe.sh and pod-logs.sh

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get pods with optional filtering by name and/or namespace
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

# Extract pod name and namespace from formatted selection string
extract_pod_info() {
    local selection="$1"
    pod_name=$(echo "$selection" | awk '{print $1}')
    namespace=$(echo "$selection" | grep -o 'ns:[^ ]*' | cut -d: -f2)
    echo "$pod_name $namespace"
}

# Check if fzf is available
check_fzf() {
    if ! command -v fzf &> /dev/null; then
        echo -e "${YELLOW}Warning: fzf not found. Using basic selection instead.${NC}"
        echo "To install fzf:"
        echo "  Ubuntu/Debian: sudo apt install fzf"
        echo "  macOS: brew install fzf"
        echo ""
        return 1
    fi
    return 0
}

# Interactive selection without fzf (numbered list)
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

# Select a pod interactively (fzf or fallback to numbered list)
# Usage: selected_pod=$(select_pod "$search_term" "$namespace" "$use_fzf" "prompt text")
select_pod() {
    local search_term="$1"
    local namespace="$2"
    local use_fzf="$3"
    local fzf_prompt="${4:-Select pod: }"

    if ! command -v kubectl &> /dev/null; then
        echo -e "${RED}Error: kubectl not found. Please install kubectl first.${NC}" >&2
        exit 1
    fi

    echo -e "${BLUE}🔍 Searching for pods...${NC}" >&2
    [[ -n "$search_term" ]] && echo -e "Searching for pods containing: ${YELLOW}$search_term${NC}" >&2
    [[ -n "$namespace" ]] && echo -e "In namespace: ${YELLOW}$namespace${NC}" >&2
    echo "" >&2

    local pods_output
    pods_output=$(get_pods "$search_term" "$namespace")

    if [[ -z "$pods_output" ]]; then
        echo -e "${RED}No pods found matching criteria.${NC}" >&2
        exit 1
    fi

    readarray -t pods_array <<< "$pods_output"

    local selected_pod
    if [[ ${#pods_array[@]} -eq 1 ]]; then
        selected_pod="${pods_array[0]}"
        echo -e "${GREEN}Found one pod: $selected_pod${NC}" >&2
    elif [[ "$use_fzf" == "true" ]] && check_fzf 2>&1 >&2; then
        selected_pod=$(printf '%s\n' "${pods_array[@]}" | fzf --prompt="$fzf_prompt" --height=20 --border --header="Use arrow keys to navigate, Enter to select")
        if [[ -z "$selected_pod" ]]; then
            echo -e "${YELLOW}No pod selected.${NC}" >&2
            exit 0
        fi
    else
        selected_pod=$(basic_selection "${pods_array[@]}")
    fi

    echo "$selected_pod"
}
