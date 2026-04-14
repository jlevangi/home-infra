#!/bin/bash
# Update K3s cluster nodes (apt update/upgrade with optional reboot)
#
# Usage:
#   ./update-k3s-nodes.sh --prod              # Update production nodes
#   ./update-k3s-nodes.sh --test              # Update test nodes
#   ./update-k3s-nodes.sh --test --no-reboot  # Update without rebooting

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../lib/environment-functions.sh"

TARGET_ENV=""
AUTO_REBOOT="true"
VERBOSITY=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --prod|--production) TARGET_ENV="prod"; shift ;;
        --test)              TARGET_ENV="test"; shift ;;
        --stage|--staging)   TARGET_ENV="stage"; shift ;;
        --no-reboot)         AUTO_REBOOT="false"; shift ;;
        -v|--verbose)        VERBOSITY="-v"; shift ;;
        --help|-h)
            echo "Usage: $0 [ENVIRONMENT] [OPTIONS]"
            echo ""
            show_environment_help "$0" "Update"
            echo "Options:"
            echo "  --no-reboot    Skip automatic reboot after updates"
            echo "  -v, --verbose  Enable verbose output"
            echo "  -h, --help     Show this help message"
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

echo "$CLUSTER_EMOJI Updating K3s $CLUSTER_NAME nodes..."
echo "🔄 Auto-reboot: $AUTO_REBOOT"
echo ""

ANSIBLE_CMD=(ansible-playbook
    -i "$INVENTORY_PATH"
    "$PROJECT_ROOT/ansible/playbooks/maintenance/update-k3s-systems.yml"
    --vault-password-file ~/.ansible_vault_pass
    -e "auto_reboot=$AUTO_REBOOT"
    -e "target_cluster=$TARGET_CLUSTER"
)

[[ -n "$VERBOSITY" ]] && ANSIBLE_CMD+=("$VERBOSITY")

"${ANSIBLE_CMD[@]}"

RESULT=$?
echo ""
if [ $RESULT -eq 0 ]; then
    echo "✅ $CLUSTER_NAME node updates complete!"
else
    echo "❌ $CLUSTER_NAME node updates failed (exit code: $RESULT)"
    exit $RESULT
fi
