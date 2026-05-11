#!/bin/bash
# =============================================================================
# List Available Longhorn Backups
# =============================================================================
# Lists backups from Longhorn Backup CR metadata. This is much faster than
# walking the shared NFS backupstore directly and matches the restore
# playbook's default discovery path.
#
# Usage:
#   ./list-backups.sh                  # List prod backups from k3s-prod
#   ./list-backups.sh --detailed       # Show individual backup IDs/timestamps
#   ./list-backups.sh --all            # Show all volume instances separately
#   ./list-backups.sh --stage          # Query the stage cluster's Longhorn API
#   ./list-backups.sh --source-env prod
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[1;36m'
NC='\033[0m'

TARGET_ENV="prod"
SOURCE_ENV="prod"
KUBE_CONTEXT=""
LONGHORN_NAMESPACE="longhorn-system"
DETAILED=false
SHOW_ALL=false

usage() {
    cat <<'EOF'
Usage: list-backups.sh [OPTIONS]

Options:
  --prod                 Query the prod cluster Longhorn API (default)
  --stage                Query the stage cluster Longhorn API
  --test                 Query the test cluster Longhorn API
  --source-env ENV       Only include backups labeled for this source env (default: prod)
  --context NAME         Override the kubectl context to query
  --longhorn-namespace   Longhorn namespace (default: longhorn-system)
  --detailed, -d         Show individual backup IDs and timestamps
  --all, -a              Show all volume instances separately
  -h, --help             Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prod)
            TARGET_ENV="prod"
            shift
            ;;
        --stage)
            TARGET_ENV="stage"
            shift
            ;;
        --test)
            TARGET_ENV="test"
            shift
            ;;
        --source-env)
            SOURCE_ENV="$2"
            shift 2
            ;;
        --context)
            KUBE_CONTEXT="$2"
            shift 2
            ;;
        --longhorn-namespace)
            LONGHORN_NAMESPACE="$2"
            shift 2
            ;;
        --detailed|-d)
            DETAILED=true
            shift
            ;;
        --all|-a)
            SHOW_ALL=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ -z "$KUBE_CONTEXT" ]]; then
    KUBE_CONTEXT="k3s-$TARGET_ENV"
fi

tmp_json=$(mktemp -t longhorn-backups-list-XXXXXX.json)
trap 'rm -f "$tmp_json"' EXIT

echo -e "${BLUE}======================================================${NC}"
echo -e "${BLUE}  Available Longhorn Backups${NC}"
echo -e "${BLUE}======================================================${NC}"
echo ""
echo "Cluster Context: $KUBE_CONTEXT"
echo "Source Filter: $SOURCE_ENV"
echo ""

kubectl --context "$KUBE_CONTEXT" -n "$LONGHORN_NAMESPACE" get backups.longhorn.io -o json > "$tmp_json"

python3 - "$tmp_json" "$DETAILED" "$SHOW_ALL" "$SOURCE_ENV" <<'PY'
import json
import sys
from collections import defaultdict
from datetime import datetime

json_path, detailed_flag, show_all_flag, source_env = sys.argv[1:5]
detailed = detailed_flag == "true"
show_all = show_all_flag == "true"
cyan = "\033[1;36m"
nc = "\033[0m"


def parse_nested_json(raw):
    if isinstance(raw, dict):
        return raw
    if not raw:
        return {}
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return {}


def parse_int(raw):
    try:
        return int(raw)
    except (TypeError, ValueError):
        return 0


def fmt_time(raw):
    try:
        return datetime.fromisoformat(raw.replace("Z", "+00:00")).strftime("%Y-%m-%d %H:%M")
    except Exception:
        return raw or "unknown"


with open(json_path, "r", encoding="utf-8") as fh:
    payload = json.load(fh)

groups = {}
group_backups = defaultdict(list)

for item in payload.get("items", []):
    metadata = item.get("metadata") or {}
    spec = item.get("spec") or {}
    status = item.get("status") or {}
    labels = status.get("labels") or spec.get("labels") or {}
    k8s = parse_nested_json(labels.get("KubernetesStatus"))

    namespace = k8s.get("namespace") or "unknown"
    pvc_name = k8s.get("pvcName") or metadata.get("labels", {}).get("backup-volume") or "unknown"
    cluster = labels.get("cluster") or "unknown"
    volume_name = status.get("volumeName") or metadata.get("labels", {}).get("backup-volume") or "unknown"
    backup_id = metadata.get("name") or "unknown"
    created = status.get("snapshotCreatedAt") or status.get("backupCreatedAt") or metadata.get("creationTimestamp") or ""
    state = status.get("state") or "unknown"
    size_bytes = parse_int(status.get("size"))

    if source_env and cluster != source_env:
        continue

    if show_all:
        key = (namespace, pvc_name, volume_name, cluster)
    else:
        key = (namespace, pvc_name)

    group = groups.get(key)
    if group is None:
        group = {
            "namespace": namespace,
            "pvc_name": pvc_name,
            "volume_name": volume_name,
            "cluster": cluster,
            "latest": created,
        }
        groups[key] = group
    elif created > group["latest"]:
        group["latest"] = created

    group_backups[key].append(
        {
            "backup_id": backup_id,
            "created": created,
            "state": state,
            "size_bytes": size_bytes,
        }
    )

if not groups:
    print("No matching backups found.")
    sys.exit(0)

ordered_keys = sorted(groups.keys(), key=lambda key: (groups[key]["namespace"], groups[key]["pvc_name"], groups[key]["latest"]))
current_namespace = None
total_backups = 0

for key in ordered_keys:
    group = groups[key]
    backups = sorted(group_backups[key], key=lambda b: (b["created"], b["backup_id"]), reverse=True)
    total_backups += len(backups)

    if group["namespace"] != current_namespace:
        if current_namespace is not None:
            print()
        print(f"{cyan}{group['namespace']}{nc}")
        current_namespace = group["namespace"]

    suffix = f" [{group['cluster']}]"
    if show_all:
        suffix += f" volume={group['volume_name']}"

    print(
        f"  {group['pvc_name']:<40} "
        f"({len(backups):>2} backups, latest: {fmt_time(group['latest'])}){suffix}"
    )

    if detailed:
        for backup in backups[:5]:
            size_mb = backup["size_bytes"] // (1024 * 1024)
            print(
                f"      - {backup['backup_id']:<24} "
                f"{fmt_time(backup['created'])} ({size_mb} MB, {backup['state']})"
            )
        if len(backups) > 5:
            print(f"      ... and {len(backups) - 5} more backups")

print()
print(f"Total: {len(groups)} PVC groups with {total_backups} backups")
PY

echo ""
echo -e "${YELLOW}Options:${NC}"
echo "  --detailed      Show individual backup IDs and timestamps"
echo "  --all           Show separate volume instances for the same PVC"
echo "  --stage|--test  Query a different cluster's Longhorn API"
echo ""
echo -e "${GREEN}To restore backups, use:${NC}"
echo "  ./scripts/restore-app.sh --prod --app bookstack"
echo "  ./scripts/restore-cluster.sh --stage --from prod"
