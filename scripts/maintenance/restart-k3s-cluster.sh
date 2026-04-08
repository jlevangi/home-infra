#!/bin/bash
# Restart a K3s cluster after maintenance shutdown
#
# Prerequisites:
#   If VMs were powered off, start them from Proxmox first.
#   The playbook will wait for SSH connectivity before proceeding.
#
# Usage:
#   ./restart-k3s-cluster.sh --prod    # Restart production cluster
#   ./restart-k3s-cluster.sh --test    # Restart test cluster
#   ./restart-k3s-cluster.sh --stage   # Restart staging cluster

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../lib/environment-functions.sh"

TARGET_ENV=""
VERBOSITY=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --prod|--production) TARGET_ENV="prod"; shift ;;
        --test)              TARGET_ENV="test"; shift ;;
        --stage|--staging)   TARGET_ENV="stage"; shift ;;
        --env)               TARGET_ENV="$2"; shift 2 ;;
        --env=*)             TARGET_ENV="${1#*=}"; shift ;;
        -v|--verbose)        VERBOSITY="-v"; shift ;;
        --help|-h)
            echo "Usage: $0 [ENVIRONMENT] [OPTIONS]"
            echo ""
            show_environment_help "$0" "Restart"
            echo "Options:"
            echo "  -v, --verbose  Enable verbose output"
            echo "  -h, --help     Show this help message"
            echo ""
            echo "Prerequisites:"
            echo "  If VMs were powered off, start them from Proxmox before running this script."
            echo "  The script will wait up to 5 minutes for SSH connectivity."
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ -z "$TARGET_ENV" ]]; then
    echo "❌ Error: Target environment must be specified"
    echo "Use --help for usage information"
    exit 1
fi

if ! setup_environment_vars "$TARGET_ENV"; then
    exit 1
fi

INVENTORY_PATH=$(get_inventory_path "$TARGET_ENV" "$PROJECT_ROOT")

echo ""
echo "$CLUSTER_EMOJI Starting K3s $CLUSTER_NAME cluster..."
echo "ℹ️  Waiting for nodes to be reachable, then starting K3s services."
echo ""

ANSIBLE_CMD=(ansible-playbook
    -i "$INVENTORY_PATH"
    "$PROJECT_ROOT/ansible/playbooks/maintenance/restart-k3s-cluster.yml"
    --vault-password-file ~/.ansible_vault_pass
    -e "target_cluster=$TARGET_CLUSTER"
    -e "kubectl_context=k3s-$KUBECTL_CONTEXT"
)

[[ -n "$VERBOSITY" ]] && ANSIBLE_CMD+=("$VERBOSITY")

"${ANSIBLE_CMD[@]}"

RESULT=$?
echo ""
if [ $RESULT -eq 0 ]; then
    echo "✅ $CLUSTER_NAME cluster is up and healthy!"
else
    echo "❌ $CLUSTER_NAME cluster restart failed (exit code: $RESULT)"
    echo "ℹ️  Check node status: kubectl --context k3s-$KUBECTL_CONTEXT get nodes"
    exit $RESULT
fi
