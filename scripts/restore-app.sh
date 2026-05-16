#!/bin/bash
# =============================================================================
# K3s Application Restore Script
# =============================================================================
# Restores one namespace or one PVC from Longhorn backups without invoking the
# full disaster-recovery workflow.
#
# Usage:
#   ./scripts/restore-app.sh --prod --app factorio
#   ./scripts/restore-app.sh --stage --from prod --app bookstack
#   ./scripts/restore-app.sh --prod --pvc factorio-data
#   ./scripts/restore-app.sh --prod --app factorio --list
#   ./scripts/restore-app.sh --prod --app gatus --backup-before 2026-05-11
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
ANSIBLE_DIR="$REPO_ROOT/ansible"

# WSL/sandbox runs can expose ~/.ansible as read-only. Force Ansible temp files
# into /tmp so restore operations can run consistently.
export TMPDIR="${TMPDIR:-/tmp}"
export ANSIBLE_LOCAL_TEMP="${ANSIBLE_LOCAL_TEMP:-/tmp/.ansible-local}"
export ANSIBLE_REMOTE_TEMP="${ANSIBLE_REMOTE_TEMP:-/tmp/.ansible-remote}"
export ANSIBLE_SSH_CONTROL_PATH_DIR="${ANSIBLE_SSH_CONTROL_PATH_DIR:-/tmp/.ansible-cp}"
mkdir -p "$ANSIBLE_LOCAL_TEMP" "$ANSIBLE_REMOTE_TEMP" "$ANSIBLE_SSH_CONTROL_PATH_DIR"

TARGET_ENV=""
SOURCE_ENV=""
RESTORE_NAMESPACE=""
RESTORE_PVC=""
RESTORE_ACTION="restore"
SKIP_CONFIRMATION=false
SKIP_PVC_LIST=""
DISCOVERY_MODE="longhorn-cr"
RESTORE_BACKUP_BEFORE=""
RESTORE_BACKUP_ID=""

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Target Environment:
  --prod                  Restore into prod
  --stage                 Restore into stage
  --test                  Restore into test

Restore Scope:
  --app NAMESPACE         Restore every PVC in this namespace
  --pvc PVC_NAME          Restore one specific PVC

Behavior:
  --from ENV              Source environment label for backup filtering (default: prod)
  --list                  List matching backups instead of restoring
  --discovery-mode MODE   Backup discovery mode: longhorn-cr or nfs-scan
  --backup-before DATE    Only consider backups strictly older than this ISO date or timestamp
  --backup-id BACKUP_ID   Restore an exact backup ID instead of the newest eligible one
  --skip-pvc PVC1,PVC2    Comma-separated PVC names to skip
  -y, --yes               Skip confirmation prompts
  -h, --help              Show this help

Examples:
  $(basename "$0") --prod --app factorio
  $(basename "$0") --stage --from prod --app bookstack
  $(basename "$0") --prod --pvc factorio-data
  $(basename "$0") --prod --app factorio --list
  $(basename "$0") --prod --app gatus --backup-before 2026-05-11
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
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
        --app)
            RESTORE_NAMESPACE="$2"
            shift 2
            ;;
        --pvc)
            RESTORE_PVC="$2"
            shift 2
            ;;
        --from)
            SOURCE_ENV="$2"
            shift 2
            ;;
        --list)
            RESTORE_ACTION="list"
            shift
            ;;
        --discovery-mode)
            DISCOVERY_MODE="$2"
            shift 2
            ;;
        --backup-before)
            RESTORE_BACKUP_BEFORE="$2"
            shift 2
            ;;
        --backup-id)
            RESTORE_BACKUP_ID="$2"
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
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

if [[ -z "$TARGET_ENV" ]]; then
    print_error "Target environment required (--prod, --stage, or --test)"
    usage
    exit 1
fi

if [[ -n "$RESTORE_NAMESPACE" && -n "$RESTORE_PVC" ]]; then
    print_error "Choose either --app or --pvc, not both"
    exit 1
fi

if [[ -z "$RESTORE_NAMESPACE" && -z "$RESTORE_PVC" ]]; then
    print_error "One restore scope is required: --app or --pvc"
    exit 1
fi

if [[ "$DISCOVERY_MODE" != "longhorn-cr" && "$DISCOVERY_MODE" != "nfs-scan" ]]; then
    print_error "Invalid --discovery-mode: $DISCOVERY_MODE"
    exit 1
fi

if ! command -v ansible-playbook >/dev/null 2>&1; then
    print_error "ansible-playbook not found"
    exit 1
fi

if [[ ! -f ~/.ansible_vault_pass ]]; then
    print_error "Ansible vault password file not found (~/.ansible_vault_pass)"
    exit 1
fi

case "$TARGET_ENV" in
    prod)  INVENTORY="$ANSIBLE_DIR/inventories/production/hosts.yml" ;;
    stage) INVENTORY="$ANSIBLE_DIR/inventories/staging/hosts.yml" ;;
    test)  INVENTORY="$ANSIBLE_DIR/inventories/test/hosts.yml" ;;
esac

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  K3s Application Restore${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""
echo "Action: $RESTORE_ACTION"
echo "Target Environment: $TARGET_ENV"
echo "Source Environment: $SOURCE_ENV"
echo "Discovery Mode: $DISCOVERY_MODE"
[[ -n "$RESTORE_BACKUP_BEFORE" ]] && echo "Backup Before: $RESTORE_BACKUP_BEFORE"
[[ -n "$RESTORE_BACKUP_ID" ]] && echo "Backup ID: $RESTORE_BACKUP_ID"
if [[ -n "$RESTORE_NAMESPACE" ]]; then
    echo "Namespace: $RESTORE_NAMESPACE"
fi
if [[ -n "$RESTORE_PVC" ]]; then
    echo "PVC: $RESTORE_PVC"
fi
[[ -n "$SKIP_PVC_LIST" ]] && echo "Skip PVCs: $SKIP_PVC_LIST"
echo ""

if [[ "$RESTORE_ACTION" == "restore" && "$SKIP_CONFIRMATION" != "true" ]]; then
    read -r -p "Type 'yes' to continue: " confirm
    if [[ "$confirm" != "yes" ]]; then
        print_error "Operation cancelled"
        exit 1
    fi
fi

extra_vars_file=$(mktemp -t restore-app-extra-vars-XXXXXX.json)
trap 'rm -f "$extra_vars_file"' EXIT

python3 - "$SKIP_PVC_LIST" "$SKIP_CONFIRMATION" "$extra_vars_file" "$DISCOVERY_MODE" "$RESTORE_BACKUP_BEFORE" "$RESTORE_BACKUP_ID" <<'PY'
import json, sys

skip_csv, skip_confirm, out_path, discovery_mode, backup_before, backup_id = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]
data = {"discovery_mode": discovery_mode}
if skip_csv:
    data["restore_pvc_skip"] = [x.strip() for x in skip_csv.split(",") if x.strip()]
if skip_confirm == "true":
    data["skip_confirm"] = True
if backup_before:
    data["restore_backup_before"] = backup_before
if backup_id:
    data["restore_backup_id"] = backup_id
with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(data, fh)
PY

extra_args=()
if [[ -n "$RESTORE_NAMESPACE" ]]; then
    extra_args+=(-e "restore_namespace_only=$RESTORE_NAMESPACE")
fi
if [[ -n "$RESTORE_PVC" ]]; then
    extra_args+=(-e "restore_pvc_only=$RESTORE_PVC")
fi
extra_args+=(-e "@$extra_vars_file")

print_info "Running Longhorn restore playbook..."

ansible-playbook \
    -i "$INVENTORY" \
    "$ANSIBLE_DIR/playbooks/k3s-restore-from-backup.yml" \
    --vault-password-file ~/.ansible_vault_pass \
    -e "restore_action=$RESTORE_ACTION" \
    -e "target_env=$TARGET_ENV" \
    -e "source_env=$SOURCE_ENV" \
    "${extra_args[@]}"
