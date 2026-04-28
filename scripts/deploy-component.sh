#!/bin/bash
# K3s Component Deployment Script
# Deploy individual infrastructure components (longhorn, metallb, traefik, argocd, vault)
# to any cluster. Applications are managed by ArgoCD, not this script.
#
# Usage:
#   ./deploy-component.sh --prod traefik          # Deploy Traefik to production
#   ./deploy-component.sh --test metallb          # Deploy MetalLB to test
#   ./deploy-component.sh --stage all-infra       # Deploy all infra to stage
#   ./deploy-component.sh --prod traefik --force  # Force redeploy
#   ./deploy-component.sh --list                  # List available components

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source environment functions
source "$SCRIPT_DIR/lib/environment-functions.sh"

# Ensure ansible/ansible.cfg is present and picked up by ansible-playbook.
require_ansible_config || exit 1

# Component definitions (ordered for fresh cluster deployment)
INFRA_COMPONENTS=("longhorn" "metallb" "traefik" "argocd" "vault")
ALL_COMPONENTS=("all-infra" "${INFRA_COMPONENTS[@]}")

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

is_valid_component() {
    local comp="$1"
    for c in "${ALL_COMPONENTS[@]}"; do
        if [[ "$c" == "$comp" ]]; then
            return 0
        fi
    done
    return 1
}

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
    echo "Note: Applications are deployed via ArgoCD (argocd/apps/<env>), not this script."
    echo ""
    echo "Usage: $0 [ENVIRONMENT] COMPONENT [OPTIONS]"
}

show_usage() {
    echo "Usage: $0 [ENVIRONMENT] COMPONENT [OPTIONS]"
    echo ""
    show_environment_help "$0" "Deploy"
    echo ""
    echo "Components:"
    echo "  Infrastructure: ${INFRA_COMPONENTS[*]}"
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
    echo "  $0 --prod argocd --force       # Force redeploy ArgoCD"
    echo "  $0 --prod traefik --dry-run    # Show commands without executing"
    echo "  $0 --list                      # List all components"
}

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

if [[ "$SHOW_HELP" == "true" ]]; then
    show_usage
    exit 0
fi

if [[ "$LIST_COMPONENTS" == "true" ]]; then
    list_components
    exit 0
fi

if [[ -z "$TARGET_ENV" ]]; then
    echo "Error: Target environment must be specified"
    echo ""
    show_usage
    exit 1
fi

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
    echo "Note: Applications are deployed via ArgoCD, not this script."
    exit 1
fi

if ! setup_environment_vars "$TARGET_ENV"; then
    exit 1
fi

EXTRA_VARS="$EXTRA_VARS -e target_cluster=$TARGET_CLUSTER"

if [[ -z "$VERBOSITY" && -n "$DEFAULT_VERBOSITY" ]]; then
    VERBOSITY="$DEFAULT_VERBOSITY"
fi

echo "Switching to $CLUSTER_NAME cluster context..."
if "$SCRIPT_DIR/helpers/k3s-context-manager.sh" switch "$KUBECTL_CONTEXT" 2>/dev/null; then
    echo "Successfully switched to k3s-$KUBECTL_CONTEXT context"
else
    echo "Warning: Failed to switch kubectl context to $KUBECTL_CONTEXT"
    echo "   Run '$SCRIPT_DIR/helpers/k3s-context-manager.sh setup' if cluster exists"
    echo "   Continuing with deployment..."
fi
echo ""

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

INVENTORY_PATH=$(get_inventory_path "$TARGET_ENV" "$PROJECT_ROOT")

build_base_cmd() {
    BASE_CMD=(ansible-playbook -i "$INVENTORY_PATH" "$PROJECT_ROOT/ansible/playbooks/k3s-deploy-component.yml" --vault-password-file ~/.ansible_vault_pass)
    if [[ -n "$VERBOSITY" ]]; then
        BASE_CMD+=("$VERBOSITY")
    fi
    BASE_CMD+=(-e "target_cluster=$TARGET_CLUSTER")
}

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
        vault)
            echo "  kubectl get pods -A -l app.kubernetes.io/name=vault"
            echo "  kubectl exec -n <vault-namespace> <vault-pod> -- vault status"
            echo "  # Prod defaults: namespace vault-raft, pod vault-raft-0"
            echo "  kubectl get externalsecrets -A"
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

# --- Single infra component deployment ---
build_infra_cmd "$COMPONENT"
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
