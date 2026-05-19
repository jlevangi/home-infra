#!/bin/bash
# Safely shut down a K3s cluster for maintenance
#
# Usage:
#   ./scripts/maintenance/shutdown-k3s-cluster.sh --prod                       # Shut down production cluster
#   ./scripts/maintenance/shutdown-k3s-cluster.sh --test --force               # Shut down test (no confirmation)
#   ./scripts/maintenance/shutdown-k3s-cluster.sh --prod --skip-vm-shutdown    # Stop K3s only, leave VMs running

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../lib/environment-functions.sh"

TARGET_ENV=""
FORCE="false"
SKIP_VM_SHUTDOWN="false"
VERBOSITY=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --prod|--production) TARGET_ENV="prod"; shift ;;
        --test)              TARGET_ENV="test"; shift ;;
        --stage|--staging)   TARGET_ENV="stage"; shift ;;
        --env)               TARGET_ENV="$2"; shift 2 ;;
        --env=*)             TARGET_ENV="${1#*=}"; shift ;;
        --force|-f)          FORCE="true"; shift ;;
        --skip-vm-shutdown)  SKIP_VM_SHUTDOWN="true"; shift ;;
        -v|--verbose)        VERBOSITY="-v"; shift ;;
        --help|-h)
            echo "Usage: $0 [ENVIRONMENT] [OPTIONS]"
            echo ""
            show_environment_help "$0" "Shutdown"
            echo "Options:"
            echo "  --force, -f          Skip confirmation prompt"
            echo "  --skip-vm-shutdown   Stop K3s services only, leave VMs running"
            echo "  -v, --verbose        Enable verbose output"
            echo "  -h, --help           Show this help message"
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

# Confirmation prompt (unless --force)
if [[ "$FORCE" != "true" ]]; then
    echo ""
    echo "$CLUSTER_EMOJI ⚠️  WARNING: This will shut down the $CLUSTER_NAME K3s cluster!"
    echo ""
    if [[ "$SKIP_VM_SHUTDOWN" == "true" ]]; then
        echo "  K3s services will be stopped (VMs will remain running)."
    else
        echo "  All cluster VMs will be powered off."
    fi
    echo ""
    echo "  Steps: cordon → drain → stop agents → stop master"
    [[ "$SKIP_VM_SHUTDOWN" == "false" ]] && echo "       → power off VMs"
    echo ""
    read -p "Are you sure? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
fi

echo ""
echo "$CLUSTER_EMOJI Shutting down K3s $CLUSTER_NAME cluster..."
[[ "$SKIP_VM_SHUTDOWN" == "true" ]] && echo "ℹ️  VM shutdown: skipped (K3s services only)"
echo ""

ANSIBLE_CMD=(ansible-playbook
    -i "$INVENTORY_PATH"
    "$PROJECT_ROOT/ansible/playbooks/maintenance/shutdown-k3s-cluster.yml"
    --vault-password-file ~/.ansible_vault_pass
    -e "target_cluster=$TARGET_CLUSTER"
    -e "kubectl_context=k3s-$KUBECTL_CONTEXT"
    -e "skip_vm_shutdown=$SKIP_VM_SHUTDOWN"
)

[[ -n "$VERBOSITY" ]] && ANSIBLE_CMD+=("$VERBOSITY")

"${ANSIBLE_CMD[@]}"

RESULT=$?
echo ""
if [ $RESULT -eq 0 ]; then
    echo "✅ $CLUSTER_NAME cluster shut down successfully!"
    if [[ "$SKIP_VM_SHUTDOWN" == "false" ]]; then
        echo "ℹ️  To restart: run ./scripts/maintenance/power-on-k3s-cluster.sh --${TARGET_ENV}"
    else
        echo "ℹ️  To restart: run ./scripts/maintenance/restart-k3s-cluster.sh --${TARGET_ENV}"
    fi
else
    echo "❌ $CLUSTER_NAME cluster shutdown failed (exit code: $RESULT)"
    exit $RESULT
fi
