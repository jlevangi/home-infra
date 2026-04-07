#!/bin/bash
# Environment Functions Library
# Provides dynamic environment detection and configuration for K3s scripts

# Get the directory of this script to locate environments.conf
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENVIRONMENTS_CONF="$SCRIPT_DIR/environments.conf"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse environment configuration and return all available environments
get_available_environments() {
    if [[ ! -f "$ENVIRONMENTS_CONF" ]]; then
        echo "prod test" # Fallback for backward compatibility
        return
    fi
    
    grep -v '^#' "$ENVIRONMENTS_CONF" | grep -v '^$' | cut -d':' -f1 | grep -v '^$' | tr '\n' ' ' | xargs
}

# Get environment configuration by name
# Usage: get_env_config "prod" "ansible_group"
# Fields: environment_name:ansible_group:display_name:emoji:kubectl_context:default_verbosity
get_env_config() {
    local env_name="$1"
    local field="$2"
    
    if [[ ! -f "$ENVIRONMENTS_CONF" ]]; then
        # Fallback for backward compatibility
        case "$env_name:$field" in
            "prod:ansible_group") echo "k3s_cluster" ;;
            "prod:display_name") echo "Production" ;;
            "prod:emoji") echo "🚀" ;;
            "prod:kubectl_context") echo "prod" ;;
            "prod:default_verbosity") echo "" ;;
            "test:ansible_group") echo "k3s_cluster_test" ;;
            "test:display_name") echo "Test" ;;
            "test:emoji") echo "🧪" ;;
            "test:kubectl_context") echo "test" ;;
            "test:default_verbosity") echo "-v" ;;
            *) echo "" ;;
        esac
        return
    fi
    
    local line=$(grep "^$env_name:" "$ENVIRONMENTS_CONF")
    if [[ -z "$line" ]]; then
        return 1
    fi
    
    case "$field" in
        "ansible_group") echo "$line" | cut -d':' -f2 ;;
        "display_name") echo "$line" | cut -d':' -f3 ;;
        "emoji") echo "$line" | cut -d':' -f4 ;;
        "kubectl_context") echo "$line" | cut -d':' -f5 ;;
        "default_verbosity") echo "$line" | cut -d':' -f6 ;;
        *) return 1 ;;
    esac
}

# Validate if an environment exists
validate_environment() {
    local env_name="$1"
    local available_envs=($(get_available_environments))
    
    for env in "${available_envs[@]}"; do
        if [[ "$env" == "$env_name" ]]; then
            return 0
        fi
    done
    return 1
}

# Show available environments with their descriptions
show_available_environments() {
    local available_envs=($(get_available_environments))
    
    echo "Available environments:"
    for env in "${available_envs[@]}"; do
        if [[ -n "$env" ]]; then
            local display_name=$(get_env_config "$env" "display_name")
            local emoji=$(get_env_config "$env" "emoji")
            local ansible_group=$(get_env_config "$env" "ansible_group")
            echo "  $env - $emoji $display_name ($ansible_group)"
        fi
    done
}

# Display environment-specific help section
show_environment_help() {
    local script_name="$1"
    local action="${2:-Deploy}"  # Default action is "Deploy"
    local available_envs=($(get_available_environments))
    
    echo "Target Selection (required):"
    
    # Show legacy flags for backward compatibility
    echo "  --prod, --production   $action to production cluster"
    echo "  --test                 $action to test cluster"
    if validate_environment "stage"; then
        echo "  --stage, --staging     $action to staging cluster"
    fi
    
    # Show new generic flag
    echo "  --env ENV              $action to specified environment"
    echo ""
    
    show_available_environments
    echo ""
    
    local action_lower=$(echo "$action" | tr '[:upper:]' '[:lower:]')
    echo "Examples:"
    echo "  $script_name --prod              # $action_lower to production"
    echo "  $script_name --test              # $action_lower to test"
    if validate_environment "stage"; then
        echo "  $script_name --stage             # $action_lower to staging"
    fi
    echo "  $script_name --env prod          # $action_lower to production (new syntax)"
    echo "  $script_name --env test          # $action_lower to test (new syntax)"
}

# Get inventory path for an environment
get_inventory_path() {
    local env_name="$1"
    local project_root="$2"
    
    case "$env_name" in
        "prod")
            echo "$project_root/ansible/inventories/production/hosts.yml"
            ;;
        "test")
            echo "$project_root/ansible/inventories/test/hosts.yml"
            ;;
        "stage")
            echo "$project_root/ansible/inventories/staging/hosts.yml"
            ;;
        *)
            # Fallback to old inventory for any custom environments
            echo "$project_root/ansible/k3s-inventory"
            ;;
    esac
}

# Setup environment variables for a given environment
setup_environment_vars() {
    local env_name="$1"
    
    if ! validate_environment "$env_name"; then
        echo -e "${RED}❌ Error: Invalid environment '$env_name'${NC}" >&2
        show_available_environments >&2
        return 1
    fi
    
    # Export environment variables for use by caller
    export TARGET_ENV="$env_name"
    export TARGET_CLUSTER=$(get_env_config "$env_name" "ansible_group")
    export CLUSTER_NAME=$(get_env_config "$env_name" "display_name")
    export CLUSTER_EMOJI=$(get_env_config "$env_name" "emoji")
    export KUBECTL_CONTEXT=$(get_env_config "$env_name" "kubectl_context")
    export DEFAULT_VERBOSITY=$(get_env_config "$env_name" "default_verbosity")
    
    return 0
}