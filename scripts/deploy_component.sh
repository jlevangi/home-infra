#!/bin/bash
# K3s Component Deployment Script
# Deploy individual infrastructure components or applications to any cluster
#
# Usage:
#   ./deploy_component.sh --prod traefik        # Deploy Traefik to production
#   ./deploy_component.sh --test metallb        # Deploy MetalLB to test
#   ./deploy_component.sh --stage bookstack     # Deploy BookStack to staging
#   ./deploy_component.sh --prod traefik --force  # Force redeploy
#   ./deploy_component.sh --list                # List available components

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source environment functions
source "$SCRIPT_DIR/environment-functions.sh"

# Component definitions (ordered for fresh cluster deployment)
INFRA_COMPONENTS=("longhorn" "metallb" "traefik" "argocd")

# Dynamically discover app components from ansible/roles/k3s-apps/tasks/apps/
APP_COMPONENTS=()
APPS_DIR="$PROJECT_ROOT/ansible/roles/k3s-apps/tasks/apps"
if [[ -d "$APPS_DIR" ]]; then
    for app_file in "$APPS_DIR"/*.yml; do
        if [[ -f "$app_file" ]]; then
            app_name=$(basename "$app_file" .yml)
            APP_COMPONENTS+=("$app_name")
        fi
    done
fi

ALL_COMPONENTS=("all-infra" "${INFRA_COMPONENTS[@]}" "${APP_COMPONENTS[@]}")

# Default values
TARGET_ENV=""
TARGET_CLUSTER=""
COMPONENT=""
EXTRA_VARS=""
VERBOSITY=""
SHOW_HELP=false
LIST_COMPONENTS=false
FORCE_REDEPLOY=false
DRY_RUN=false

# Check if component is valid
is_valid_component() {
    local comp="$1"
    for c in "${ALL_COMPONENTS[@]}"; do
        if [[ "$c" == "$comp" ]]; then
            return 0
        fi
    done
    return 1
}

# Check if component is infrastructure
is_infra_component() {
    local comp="$1"
    for c in "${INFRA_COMPONENTS[@]}"; do
        if [[ "$c" == "$comp" ]]; then
            return 0
        fi
    done
    return 1
}

# List components
list_components() {
    echo "Available Components"
    echo "===================="
    echo ""
    echo "Infrastructure:"
    echo "  - all-infra  (deploy all infra in order: ${INFRA_COMPONENTS[*]})"
    for c in "${INFRA_COMPONENTS[@]}"; do
        echo "  - $c"
    done
    echo ""
    echo "Applications:"
    for c in "${APP_COMPONENTS[@]}"; do
        echo "  - $c"
    done
    echo ""
    echo "Usage: $0 [ENVIRONMENT] COMPONENT [OPTIONS]"
}

# Show usage
show_usage() {
    echo "Usage: $0 [ENVIRONMENT] COMPONENT [OPTIONS]"
    echo ""
    show_environment_help "$0" "Deploy"
    echo ""
    echo "Components:"
    echo "  Infrastructure: ${INFRA_COMPONENTS[*]}"
    echo "  Applications:   ${APP_COMPONENTS[*]}"
    echo ""
    echo "Options:"
    echo "  --list               List all available components"
    echo "  --force              Force redeploy (cleanup and reinstall)"
    echo "  --dry-run            Show what would be executed without running"
    echo "  -v, --verbose        Enable verbose output"
    echo "  -vv, -vvv            Enable more verbose output"
    echo "  -q, --quiet          Disable verbose output"
    echo "  -h, --help           Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 --test all-infra            # Deploy all infra to test (fresh cluster)"
    echo "  $0 --prod traefik              # Deploy Traefik to production"
    echo "  $0 --test metallb              # Deploy MetalLB to test"
    echo "  $0 --stage bookstack           # Deploy BookStack to staging"
    echo "  $0 --prod homepage --force     # Force redeploy Homepage"
    echo "  $0 --prod traefik --dry-run    # Show commands without executing"
    echo "  $0 --list                      # List all components"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --prod|--production)
            TARGET_ENV="prod"
            shift
            ;;
        --test)
            TARGET_ENV="test"
            shift
            ;;
        --stage|--staging)
            TARGET_ENV="stage"
            shift
            ;;
        --env)
            if [[ -n "$2" && "$2" != -* ]]; then
                TARGET_ENV="$2"
                shift 2
            else
                echo "Error: --env requires an environment name"
                exit 1
            fi
            ;;
        --env=*)
            TARGET_ENV="${1#--env=}"
            shift
            ;;
        --list)
            LIST_COMPONENTS=true
            shift
            ;;
        --force)
            FORCE_REDEPLOY=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -v|--verbose)
            VERBOSITY="-v"
            shift
            ;;
        -vv)
            VERBOSITY="-vv"
            shift
            ;;
        -vvv)
            VERBOSITY="-vvv"
            shift
            ;;
        --quiet|-q)
            VERBOSITY=""
            shift
            ;;
        --help|-h)
            SHOW_HELP=true
            shift
            ;;
        -*)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
        *)
            # Assume it's the component name
            if [[ -z "$COMPONENT" ]]; then
                COMPONENT="$1"
            else
                echo "Error: Multiple components specified. Deploy one at a time."
                exit 1
            fi
            shift
            ;;
    esac
done

# Handle help
if [[ "$SHOW_HELP" == "true" ]]; then
    show_usage
    exit 0
fi

# Handle list
if [[ "$LIST_COMPONENTS" == "true" ]]; then
    list_components
    exit 0
fi

# Validate environment
if [[ -z "$TARGET_ENV" ]]; then
    echo "Error: Target environment must be specified"
    echo ""
    show_usage
    exit 1
fi

# Validate component
if [[ -z "$COMPONENT" ]]; then
    echo "Error: Component name must be specified"
    echo ""
    show_usage
    exit 1
fi

if ! is_valid_component "$COMPONENT"; then
    echo "Error: Unknown component '$COMPONENT'"
    echo ""
    echo "Available components: ${ALL_COMPONENTS[*]}"
    exit 1
fi

# Set up target-specific variables using environment functions
if ! setup_environment_vars "$TARGET_ENV"; then
    exit 1
fi

# Set up Ansible extra vars for target cluster
EXTRA_VARS="$EXTRA_VARS -e target_cluster=$TARGET_CLUSTER"

# Apply default verbosity if not explicitly set and environment has a default
if [[ -z "$VERBOSITY" && -n "$DEFAULT_VERBOSITY" ]]; then
    VERBOSITY="$DEFAULT_VERBOSITY"
fi

# Switch to the appropriate kubectl context
echo "Switching to $CLUSTER_NAME cluster context..."
if "$SCRIPT_DIR/k3s-context-manager.sh" switch "$KUBECTL_CONTEXT" 2>/dev/null; then
    echo "Successfully switched to k3s-$KUBECTL_CONTEXT context"
else
    echo "Warning: Failed to switch kubectl context to $KUBECTL_CONTEXT"
    echo "   Run '$SCRIPT_DIR/k3s-context-manager.sh setup' if cluster exists"
    echo "   Continuing with deployment..."
fi
echo ""

# Display deployment info
echo "$CLUSTER_EMOJI Deploying $COMPONENT to $CLUSTER_NAME cluster"
echo "============================================="
echo "Environment: $TARGET_ENV ($TARGET_CLUSTER)"
echo "Component:   $COMPONENT"
if [[ "$COMPONENT" == "all-infra" ]]; then
    echo "Components:  ${INFRA_COMPONENTS[*]}"
fi
echo "Force:       $([ "$FORCE_REDEPLOY" == "true" ] && echo "yes" || echo "no")"
echo "Verbosity:   $([ -n "$VERBOSITY" ] && echo "$VERBOSITY" || echo "standard")"
echo ""

# Get the appropriate inventory path for this environment
INVENTORY_PATH=$(get_inventory_path "$TARGET_ENV" "$PROJECT_ROOT")

# Build the base ansible command (shared by single and all-infra paths)
build_base_cmd() {
    BASE_CMD=(ansible-playbook -i "$INVENTORY_PATH" "$PROJECT_ROOT/ansible/playbooks/k3s-deploy-component.yml" --vault-password-file ~/.ansible_vault_pass)
    if [[ -n "$VERBOSITY" ]]; then
        BASE_CMD+=("$VERBOSITY")
    fi
    BASE_CMD+=(-e "target_cluster=$TARGET_CLUSTER")
}

# Build the full ansible command for a single infra component
build_infra_cmd() {
    local comp="$1"
    build_base_cmd
    ANSIBLE_CMD=("${BASE_CMD[@]}" -e "deploy_component=$comp")

    if [[ "$FORCE_REDEPLOY" == "true" ]]; then
        case "$comp" in
            traefik)
                ANSIBLE_CMD+=(-e '{"force_traefik_redeploy": true}')
                ;;
            metallb)
                ANSIBLE_CMD+=(-e '{"force_metallb_redeploy": true}')
                ;;
            longhorn)
                echo "Note: Longhorn will be upgraded/reinstalled via Helm"
                ;;
            argocd)
                ANSIBLE_CMD+=(-e '{"force_argocd_redeploy": true}')
                ;;
        esac
    fi
}

# Run a single component and handle result
run_component() {
    local comp="$1"
    echo "Ansible command:"
    echo "  ${ANSIBLE_CMD[*]}"
    echo ""

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "(Dry run - command not executed)"
        return 0
    fi

    "${ANSIBLE_CMD[@]}"
    return $?
}

# Show verification commands for a component
show_verification() {
    local comp="$1"
    echo "Verification commands:"
    case "$comp" in
        traefik)
            echo "  kubectl get pods -n traefik-system"
            echo "  kubectl get svc -n traefik-system"
            echo "  kubectl get ingressroute -n traefik-system"
            ;;
        metallb)
            echo "  kubectl get pods -n metallb-system"
            echo "  kubectl get ipaddresspool -n metallb-system"
            ;;
        longhorn)
            echo "  kubectl get pods -n longhorn-system"
            echo "  kubectl get sc longhorn"
            ;;
        argocd)
            echo "  kubectl get pods -n argocd"
            echo "  kubectl get svc -n argocd"
            echo "  kubectl get ingressroute -n argocd"
            echo "  kubectl get applications -A"
            echo ""
            echo "  # Get initial admin password:"
            echo "  kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d; echo"
            ;;
        *)
            echo "  kubectl get pods -n $comp"
            echo "  kubectl get svc -n $comp"
            echo "  kubectl get ingress -n $comp"
            ;;
    esac
}

# --- all-infra: deploy each infra component in order ---
if [[ "$COMPONENT" == "all-infra" ]]; then
    FAILED_COMPONENTS=()
    SUCCEEDED_COMPONENTS=()

    for infra_comp in "${INFRA_COMPONENTS[@]}"; do
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "$CLUSTER_EMOJI [$((${#SUCCEEDED_COMPONENTS[@]}+${#FAILED_COMPONENTS[@]}+1))/${#INFRA_COMPONENTS[@]}] Deploying $infra_comp"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        build_infra_cmd "$infra_comp"
        run_component "$infra_comp"
        RESULT=$?

        if [[ $RESULT -eq 0 ]]; then
            SUCCEEDED_COMPONENTS+=("$infra_comp")
        else
            FAILED_COMPONENTS+=("$infra_comp")
            echo ""
            echo "ERROR: $infra_comp failed (exit code: $RESULT) — skipping remaining components"
            break
        fi
    done

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "$CLUSTER_EMOJI Infrastructure Deployment Summary"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [[ ${#SUCCEEDED_COMPONENTS[@]} -gt 0 ]]; then
        echo "  Succeeded: ${SUCCEEDED_COMPONENTS[*]}"
    fi
    if [[ ${#FAILED_COMPONENTS[@]} -gt 0 ]]; then
        echo "  Failed:    ${FAILED_COMPONENTS[*]}"
        exit 1
    fi
    echo ""
    echo "All infrastructure components deployed successfully!"
    exit 0
fi

# --- Single component deployment ---
if is_infra_component "$COMPONENT"; then
    build_infra_cmd "$COMPONENT"
else
    build_base_cmd
    ANSIBLE_CMD=("${BASE_CMD[@]}" -e "deploy_single_app=$COMPONENT")

    if [[ "$FORCE_REDEPLOY" == "true" ]]; then
        ANSIBLE_CMD+=(-e "force_redeploy_apps=['$COMPONENT']")
    fi
fi

run_component "$COMPONENT"
RESULT=$?

echo ""
if [[ $RESULT -eq 0 ]]; then
    echo "$CLUSTER_EMOJI $COMPONENT deployment to $CLUSTER_NAME complete!"
    echo ""
    show_verification "$COMPONENT"
else
    echo "Deployment of $COMPONENT to $CLUSTER_NAME failed (exit code: $RESULT)"
    exit $RESULT
fi
