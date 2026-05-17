#!/bin/bash
# Recover Vault for a target K3s cluster by running the maintenance playbook.
#
# Usage:
#   ./scripts/maintenance/recover-vault.sh --prod
#   ./scripts/maintenance/recover-vault.sh --stage
#   ./scripts/maintenance/recover-vault.sh --test -v

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$PROJECT_ROOT/scripts/lib/environment-functions.sh"

require_ansible_config || exit 1

VAULT_PASSWORD_FILE="$(get_ansible_vault_password_file)"

TARGET_ENV=""
VERBOSITY=""
SWITCH_CONTEXT=true

show_usage() {
    echo "Usage: $0 [ENVIRONMENT] [OPTIONS]"
    echo ""
    show_environment_help "$0" "Recover Vault on"
    echo "Options:"
    echo "  --skip-context-switch  Do not switch kubectl context before running"
    echo "  -v, --verbose          Enable verbose output"
    echo "  -vv, -vvv              Enable more verbose output"
    echo "  -q, --quiet            Disable verbose output"
    echo "  -h, --help             Show this help message"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prod|--production) TARGET_ENV="prod"; shift ;;
        --test)              TARGET_ENV="test"; shift ;;
        --stage|--staging)   TARGET_ENV="stage"; shift ;;
        --env)
            if [[ -n "${2:-}" && "${2:-}" != -* ]]; then
                TARGET_ENV="$2"
                shift 2
            else
                echo "Error: --env requires an environment name"
                exit 1
            fi
            ;;
        --env=*)             TARGET_ENV="${1#--env=}"; shift ;;
        --skip-context-switch) SWITCH_CONTEXT=false; shift ;;
        -v|--verbose)        VERBOSITY="-v"; shift ;;
        -vv)                 VERBOSITY="-vv"; shift ;;
        -vvv)                VERBOSITY="-vvv"; shift ;;
        -q|--quiet)          VERBOSITY=""; shift ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo ""
            show_usage
            exit 1
            ;;
    esac
done

if [[ -z "$TARGET_ENV" ]]; then
    echo "Error: Target environment must be specified"
    echo ""
    show_usage
    exit 1
fi

setup_environment_vars "$TARGET_ENV" || exit 1

INVENTORY_PATH=$(get_inventory_path "$TARGET_ENV" "$PROJECT_ROOT")

if [[ -z "$VERBOSITY" && -n "$DEFAULT_VERBOSITY" ]]; then
    VERBOSITY="$DEFAULT_VERBOSITY"
fi

if [[ "$SWITCH_CONTEXT" == true ]]; then
    echo "Switching to $CLUSTER_NAME cluster context..."
    if "$PROJECT_ROOT/scripts/k3s/helpers/k3s-context-manager.sh" switch "$KUBECTL_CONTEXT" 2>/dev/null; then
        echo "Successfully switched to k3s-$KUBECTL_CONTEXT context"
    else
        echo "Warning: Failed to switch kubectl context to $KUBECTL_CONTEXT"
        echo "   Run '$PROJECT_ROOT/scripts/k3s/helpers/k3s-context-manager.sh setup' if needed"
        echo "   Continuing with recovery..."
    fi
    echo ""
fi

echo "$CLUSTER_EMOJI Recovering Vault for $CLUSTER_NAME cluster"
echo "============================================="
echo "Environment: $TARGET_ENV ($TARGET_CLUSTER)"
echo "Context:     k3s-$KUBECTL_CONTEXT"
echo ""

ANSIBLE_CMD=(
    ansible-playbook
    -i "$INVENTORY_PATH"
    "$PROJECT_ROOT/ansible/playbooks/maintenance/vault-unseal.yml"
    --vault-password-file "$VAULT_PASSWORD_FILE"
    -e "target_cluster=$TARGET_CLUSTER"
    -e "kubectl_context=k3s-$KUBECTL_CONTEXT"
)

[[ -n "$VERBOSITY" ]] && ANSIBLE_CMD+=("$VERBOSITY")

"${ANSIBLE_CMD[@]}"
RESULT=$?

echo ""
if [[ $RESULT -eq 0 ]]; then
    echo "✅ Vault recovery completed for $CLUSTER_NAME cluster."
else
    echo "❌ Vault recovery failed for $CLUSTER_NAME cluster (exit code: $RESULT)"
fi

exit $RESULT
