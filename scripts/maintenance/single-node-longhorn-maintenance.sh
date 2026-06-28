#!/bin/bash
# Prepare or restore a single K3s node for maintenance without triggering
# unnecessary Longhorn replica rebuilds.
#
# Examples:
#   ./scripts/maintenance/single-node-longhorn-maintenance.sh --prod --node k3s-prod-worker-gpu-1 --prepare
#   ./scripts/maintenance/single-node-longhorn-maintenance.sh --prod --node k3s-prod-worker-gpu-1 --restore

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../lib/environment-functions.sh"

TARGET_ENV=""
TARGET_NODE=""
ACTION="prepare"
FORCE="false"
VERBOSITY=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --prod|--production) TARGET_ENV="prod"; shift ;;
        --test)              TARGET_ENV="test"; shift ;;
        --stage|--staging)   TARGET_ENV="stage"; shift ;;
        --env)               TARGET_ENV="$2"; shift 2 ;;
        --env=*)             TARGET_ENV="${1#*=}"; shift ;;
        --node)              TARGET_NODE="$2"; shift 2 ;;
        --node=*)            TARGET_NODE="${1#*=}"; shift ;;
        --prepare)           ACTION="prepare"; shift ;;
        --restore)           ACTION="restore"; shift ;;
        --force|-f)          FORCE="true"; shift ;;
        -v|--verbose)        VERBOSITY="-v"; shift ;;
        --help|-h)
            echo "Usage: $0 [ENVIRONMENT] --node <node-name> (--prepare|--restore) [OPTIONS]"
            echo ""
            show_environment_help "$0" "single-node Longhorn-safe maintenance"
            echo "Options:"
            echo "  --node <name>        Kubernetes node name to maintain"
            echo "  --prepare            Cordon, pause Longhorn rebuilds, scale configured workloads down"
            echo "  --restore            Wait Ready, uncordon, restore Longhorn settings, scale workloads up"
            echo "  --force, -f          Skip confirmation prompt"
            echo "  -v, --verbose        Enable verbose Ansible output"
            echo "  -h, --help           Show this help message"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ -z "$TARGET_ENV" ]]; then
    echo "❌ Error: target environment must be specified"
    exit 1
fi

if [[ -z "$TARGET_NODE" ]]; then
    echo "❌ Error: --node is required"
    exit 1
fi

if ! setup_environment_vars "$TARGET_ENV"; then
    exit 1
fi

if ! require_ansible_config; then
    exit 1
fi

INVENTORY_PATH=$(get_inventory_path "$TARGET_ENV" "$PROJECT_ROOT")
VAULT_PASSWORD_FILE="$(get_ansible_vault_password_file)"

if [[ "$FORCE" != "true" ]]; then
    echo ""
    echo "$CLUSTER_EMOJI Single-node maintenance: $TARGET_NODE on $CLUSTER_NAME"
    echo ""
    if [[ "$ACTION" == "prepare" ]]; then
        echo "  Steps: extend Longhorn replica replenishment wait → disable Longhorn scheduling"
        echo "       → cordon node → scale configured node workloads to zero"
        echo "       → wait for Longhorn volumes to detach"
        echo ""
        echo "  The VM will NOT be powered off by this script."
    else
        echo "  Steps: wait for node Ready → re-enable Longhorn scheduling → restore Longhorn wait"
        echo "       → uncordon node → scale configured workloads back up"
    fi
    echo ""
    read -r -p "Continue? (y/N) " REPLY
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
fi

ANSIBLE_CMD=(ansible-playbook
    -i "$INVENTORY_PATH"
    "$PROJECT_ROOT/ansible/playbooks/maintenance/single-node-longhorn-maintenance.yml"
    --vault-password-file "$VAULT_PASSWORD_FILE"
    -e "target_cluster=$TARGET_CLUSTER"
    -e "target_node=$TARGET_NODE"
    -e "maintenance_action=$ACTION"
)

[[ -n "$VERBOSITY" ]] && ANSIBLE_CMD+=("$VERBOSITY")

"${ANSIBLE_CMD[@]}"
