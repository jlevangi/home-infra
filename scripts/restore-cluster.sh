#!/bin/bash
# =============================================================================
# K3s Cluster Disaster Recovery Script
# =============================================================================
# This script provides one-click disaster recovery for K3s clusters.
#
# Use Cases:
#   1. Full DR: Rebuild VMs, deploy K3s, restore data from backups
#   2. Data Restore Only: Restore data to existing cluster
#   3. Clone Prod to Stage: Rebuild stage with prod's data
#
# Usage:
#   ./restore_cluster.sh --prod              # Full DR for production
#   ./restore_cluster.sh --stage             # Rebuild stage with prod data
#   ./restore_cluster.sh --prod --restore-only  # Just restore data (no rebuild)
#   ./restore_cluster.sh --stage --from prod    # Clone prod to stage
#
# =============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
ANSIBLE_DIR="$REPO_ROOT/ansible"

# Default values
TARGET_ENV=""
SOURCE_ENV=""
REBUILD_VMS=true
RESTORE_DATA=true
SKIP_CONFIRMATION=false
SPECIFIC_NAMESPACE=""
SPECIFIC_PVC=""
SKIP_PVC_LIST=""

# =============================================================================
# Functions
# =============================================================================

print_banner() {
    echo -e "${BLUE}"
    echo "============================================================"
    echo "  K3s Cluster Disaster Recovery"
    echo "============================================================"
    echo -e "${NC}"
}

print_step() {
    echo -e "${GREEN}[STEP]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Disaster Recovery Options:
  --prod              Target production environment
  --stage             Target staging environment
  --test              Target test environment

Recovery Mode Options:
  --restore-only          Skip VM rebuild, only restore data
  --rebuild-only          Only rebuild VMs and deploy K3s, no data restore
  --from ENV              Source environment for backup data (default: prod)
  --app NAMESPACE         Restore every PVC in this namespace (e.g., --app bookstack)
  --pvc PVC_NAME          Restore one specific PVC (e.g., --pvc bookstack-app-data-pvc)
  --skip-pvc PVC1,PVC2    Comma-separated PVC names to skip (e.g., stale apps)

Other Options:
  -y, --yes               Skip confirmation prompts
  -h, --help              Show this help message

Examples:
  # Full disaster recovery for production
  $(basename "$0") --prod

  # Rebuild stage cluster with production data
  $(basename "$0") --stage --from prod

  # Restore only (no VM rebuild) for production
  $(basename "$0") --prod --restore-only

  # Restore every PVC in the bookstack namespace
  $(basename "$0") --stage --from prod --app bookstack --restore-only

  # Restore everything except known-stale PVCs (deleted apps)
  $(basename "$0") --prod --restore-only --skip-pvc homepage-config,plex-config-pvc

EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --prod)
                TARGET_ENV="prod"
                SOURCE_ENV="${SOURCE_ENV:-prod}"
                shift
                ;;
            --stage)
                TARGET_ENV="stage"
                SOURCE_ENV="${SOURCE_ENV:-prod}"
                shift
                ;;
            --test)
                TARGET_ENV="test"
                SOURCE_ENV="${SOURCE_ENV:-prod}"
                shift
                ;;
            --restore-only)
                REBUILD_VMS=false
                shift
                ;;
            --rebuild-only)
                RESTORE_DATA=false
                shift
                ;;
            --from)
                SOURCE_ENV="$2"
                shift 2
                ;;
            --app)
                SPECIFIC_NAMESPACE="$2"
                shift 2
                ;;
            --pvc)
                SPECIFIC_PVC="$2"
                shift 2
                ;;
            --skip-pvc)
                SKIP_PVC_LIST="$2"
                shift 2
                ;;
            -y|--yes)
                SKIP_CONFIRMATION=true
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                print_error "Unknown option: $1"
                usage
                ;;
        esac
    done

    if [[ -z "$TARGET_ENV" ]]; then
        print_error "Target environment required (--prod, --stage, or --test)"
        usage
    fi
}

confirm_operation() {
    if [[ "$SKIP_CONFIRMATION" == "true" ]]; then
        return 0
    fi

    echo ""
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}  DISASTER RECOVERY CONFIRMATION${NC}"
    echo -e "${YELLOW}========================================${NC}"
    echo ""
    echo "Target Environment: $TARGET_ENV"
    echo "Source Environment: $SOURCE_ENV"
    echo "Rebuild VMs: $REBUILD_VMS"
    echo "Restore Data: $RESTORE_DATA"
    [[ -n "$SPECIFIC_NAMESPACE" ]] && echo "Namespace filter: $SPECIFIC_NAMESPACE"
    [[ -n "$SPECIFIC_PVC" ]] && echo "PVC filter: $SPECIFIC_PVC"
    [[ -n "$SKIP_PVC_LIST" ]] && echo "Skip PVCs: $SKIP_PVC_LIST"
    echo ""

    if [[ "$REBUILD_VMS" == "true" ]]; then
        echo -e "${RED}WARNING: This will DESTROY and REBUILD the $TARGET_ENV cluster!${NC}"
        echo -e "${RED}All existing VMs will be deleted and recreated.${NC}"
    fi

    if [[ "$RESTORE_DATA" == "true" ]]; then
        echo -e "${YELLOW}Data will be restored from $SOURCE_ENV backups.${NC}"
    fi

    echo ""
    read -p "Are you sure you want to proceed? (type 'yes' to confirm): " confirm

    if [[ "$confirm" != "yes" ]]; then
        print_error "Operation cancelled"
        exit 1
    fi
}

check_prerequisites() {
    print_step "Checking prerequisites..."

    # Check ansible
    if ! command -v ansible-playbook &> /dev/null; then
        print_error "ansible-playbook not found"
        exit 1
    fi

    # Check terraform (if rebuilding)
    if [[ "$REBUILD_VMS" == "true" ]]; then
        if ! command -v terraform &> /dev/null; then
            print_error "terraform not found (required for VM rebuild)"
            exit 1
        fi
    fi

    # Check vault password file
    if [[ ! -f ~/.ansible_vault_pass ]]; then
        print_error "Ansible vault password file not found (~/.ansible_vault_pass)"
        exit 1
    fi

    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl not found"
        exit 1
    fi

    print_info "Prerequisites check passed"
}

rebuild_vms() {
    if [[ "$REBUILD_VMS" != "true" ]]; then
        print_info "Skipping VM rebuild (--restore-only specified)"
        return 0
    fi

    print_step "Rebuilding VMs for $TARGET_ENV environment..."

    # Use the rebuild script if available
    if [[ -f "$SCRIPT_DIR/rebuild-k3s-cluster.sh" ]]; then
        "$SCRIPT_DIR/rebuild-k3s-cluster.sh" --$TARGET_ENV --yes
    else
        # Manual terraform destroy/apply
        local terraform_dir=""
        case $TARGET_ENV in
            prod)  terraform_dir="$REPO_ROOT/terraform/k3_3node_cluster_prod" ;;
            stage) terraform_dir="$REPO_ROOT/terraform/k3_3node_cluster_stage" ;;
            test)  terraform_dir="$REPO_ROOT/terraform/k3_3node_cluster_test" ;;
        esac

        if [[ -d "$terraform_dir" ]]; then
            print_step "Destroying existing VMs..."
            cd "$terraform_dir"
            terraform destroy -auto-approve

            print_step "Creating new VMs..."
            terraform apply -auto-approve
            cd "$REPO_ROOT"
        else
            print_error "Terraform directory not found: $terraform_dir"
            exit 1
        fi
    fi

    # Wait for VMs to be ready
    print_step "Waiting for VMs to initialize..."
    sleep 60
}

deploy_k3s() {
    if [[ "$REBUILD_VMS" != "true" ]]; then
        print_info "Skipping K3s deployment (using existing cluster)"
        return 0
    fi

    print_step "Deploying K3s cluster..."

    "$SCRIPT_DIR/deploy-k3s-cluster.sh" --$TARGET_ENV
}

switch_context() {
    print_step "Switching to $TARGET_ENV cluster context..."
    "$SCRIPT_DIR/helpers/k3s-context-manager.sh" switch $TARGET_ENV
}

restore_data() {
    if [[ "$RESTORE_DATA" != "true" ]]; then
        print_info "Skipping data restore (--rebuild-only specified)"
        return 0
    fi

    print_step "Restoring data from $SOURCE_ENV backups..."

    # Determine inventory based on target environment
    local inventory=""
    case $TARGET_ENV in
        prod)  inventory="$ANSIBLE_DIR/inventories/production/hosts.yml" ;;
        stage) inventory="$ANSIBLE_DIR/inventories/staging/hosts.yml" ;;
        test)  inventory="$ANSIBLE_DIR/inventories/test/hosts.yml" ;;
    esac

    local extra_args=()
    [[ -n "$SPECIFIC_NAMESPACE" ]] && extra_args+=(-e "restore_namespace_only=$SPECIFIC_NAMESPACE")
    [[ -n "$SPECIFIC_PVC" ]] && extra_args+=(-e "restore_pvc_only=$SPECIFIC_PVC")
    if [[ -n "$SKIP_PVC_LIST" ]]; then
        # Convert comma-separated list to JSON array for Ansible
        local skip_json
        skip_json=$(printf '%s' "$SKIP_PVC_LIST" | python3 -c 'import sys,json; print(json.dumps([x.strip() for x in sys.stdin.read().split(",") if x.strip()]))')
        extra_args+=(-e "restore_pvc_skip=$skip_json")
    fi

    # Run the restore playbook
    ansible-playbook \
        -i "$inventory" \
        "$ANSIBLE_DIR/playbooks/k3s-restore-from-backup.yml" \
        --vault-password-file ~/.ansible_vault_pass \
        -e "restore_action=restore" \
        -e "target_env=$TARGET_ENV" \
        -e "source_env=$SOURCE_ENV" \
        "${extra_args[@]}"
}

verify_cluster() {
    print_step "Verifying cluster health..."

    echo ""
    echo "Cluster Nodes:"
    kubectl get nodes

    echo ""
    echo "All Pods:"
    kubectl get pods -A

    echo ""
    echo "Persistent Volume Claims:"
    kubectl get pvc -A

    echo ""
    echo "Ingresses:"
    kubectl get ingress -A
}

print_summary() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  DISASTER RECOVERY COMPLETE${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo "Target Environment: $TARGET_ENV"
    echo "Source Environment: $SOURCE_ENV"
    echo ""

    if [[ "$REBUILD_VMS" == "true" ]]; then
        echo "- VMs rebuilt successfully"
        echo "- K3s cluster deployed"
    fi

    if [[ "$RESTORE_DATA" == "true" ]]; then
        echo "- Data restored from backups"
        echo "- Applications deployed"
    fi

    echo ""
    echo "Next Steps:"
    echo "1. Verify applications at their URLs"
    echo "2. Check Longhorn UI for volume health"
    echo "3. Update DNS if IP addresses changed"
    echo ""

    # Display URLs based on environment
    case $TARGET_ENV in
        prod)
            echo "Application URLs:"
            echo "  - https://bookstack.levangie.dev"
            echo "  - https://vw.levangie.dev"
            echo "  - https://homepage.levangie.dev"
            echo "  - https://longhorn.levangie.dev"
            ;;
        stage)
            echo "Application URLs:"
            echo "  - https://bookstack.stage.levangie.dev"
            echo "  - https://vw.stage.levangie.dev"
            echo "  - https://homepage.stage.levangie.dev"
            echo "  - https://longhorn.stage.levangie.dev"
            ;;
        test)
            echo "Application URLs:"
            echo "  - https://bookstack.test.levangie.dev"
            echo "  - https://vw.test.levangie.dev"
            echo "  - https://homepage.test.levangie.dev"
            echo "  - https://longhorn.test.levangie.dev"
            ;;
    esac
}

# =============================================================================
# Main
# =============================================================================

main() {
    print_banner
    parse_args "$@"
    confirm_operation
    check_prerequisites

    # Execute recovery steps
    rebuild_vms
    deploy_k3s
    switch_context
    restore_data
    verify_cluster
    print_summary
}

main "$@"
