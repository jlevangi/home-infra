#!/bin/bash
# Power on a K3s cluster's Proxmox VMs, then run the standard restart flow.
#
# Usage:
#   ./scripts/maintenance/power-on-k3s-cluster.sh --prod
#   ./scripts/maintenance/power-on-k3s-cluster.sh --stage --force
#   ./scripts/maintenance/power-on-k3s-cluster.sh --test --skip-vault-unseal

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../lib/environment-functions.sh"

VAULT_PASSWORD_FILE="$(get_ansible_vault_password_file)"

TARGET_ENV=""
FORCE="false"
VERBOSITY=""
SKIP_VAULT_UNSEAL="false"
VAULT_CLUSTER_CERT_RECOVERY="true"

while [[ $# -gt 0 ]]; do
    case $1 in
        --prod|--production) TARGET_ENV="prod"; shift ;;
        --test)              TARGET_ENV="test"; shift ;;
        --stage|--staging)   TARGET_ENV="stage"; shift ;;
        --env)               TARGET_ENV="$2"; shift 2 ;;
        --env=*)             TARGET_ENV="${1#*=}"; shift ;;
        --force|-f)          FORCE="true"; shift ;;
        -v|--verbose)        VERBOSITY="-v"; shift ;;
        --skip-vault-unseal) SKIP_VAULT_UNSEAL="true"; shift ;;
        --no-cluster-cert-recovery) VAULT_CLUSTER_CERT_RECOVERY="false"; shift ;;
        --help|-h)
            echo "Usage: $0 [ENVIRONMENT] [OPTIONS]"
            echo ""
            show_environment_help "$0" "Power on"
            echo "Options:"
            echo "  --force, -f          Skip confirmation prompt"
            echo "  --skip-vault-unseal  Skip Vault unseal/auth refresh after restart"
            echo "  --no-cluster-cert-recovery"
            echo "                       Detect Vault Raft cluster-cert drift but do not auto-heal it"
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

if ! require_ansible_config; then
    exit 1
fi

INVENTORY_PATH=$(get_inventory_path "$TARGET_ENV" "$PROJECT_ROOT")

if [[ "$FORCE" != "true" ]]; then
    echo ""
    echo "$CLUSTER_EMOJI This will power on the $CLUSTER_NAME K3s cluster VMs and run the restart workflow."
    echo ""
    echo "  Steps: power on Proxmox VMs → wait for VMs to be running → restart K3s services"
    [[ "$SKIP_VAULT_UNSEAL" == "false" ]] && echo "       → unseal/refresh Vault auth"
    echo ""
    read -p "Continue? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
fi

echo ""
echo "$CLUSTER_EMOJI Powering on K3s $CLUSTER_NAME cluster VMs..."
echo ""

ANSIBLE_CMD=(ansible-playbook
    -i "$INVENTORY_PATH"
    "$PROJECT_ROOT/ansible/playbooks/maintenance/power-on-k3s-cluster.yml"
    --vault-password-file "$VAULT_PASSWORD_FILE"
    -e "target_cluster=$TARGET_CLUSTER"
)

[[ -n "$VERBOSITY" ]] && ANSIBLE_CMD+=("$VERBOSITY")

"${ANSIBLE_CMD[@]}"

RESULT=$?
echo ""
if [ $RESULT -ne 0 ]; then
    echo "❌ $CLUSTER_NAME VM power-on failed (exit code: $RESULT)"
    exit $RESULT
fi

echo "✅ $CLUSTER_NAME VMs are running in Proxmox."
echo ""

RESTART_CMD=("$PROJECT_ROOT/scripts/maintenance/restart-k3s-cluster.sh" "--$TARGET_ENV")

[[ -n "$VERBOSITY" ]] && RESTART_CMD+=("$VERBOSITY")
[[ "$SKIP_VAULT_UNSEAL" == "true" ]] && RESTART_CMD+=("--skip-vault-unseal")
[[ "$VAULT_CLUSTER_CERT_RECOVERY" == "false" ]] && RESTART_CMD+=("--no-cluster-cert-recovery")

"${RESTART_CMD[@]}"
