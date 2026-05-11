#!/bin/bash
set -euo pipefail

LONGHORN_NAMESPACE="longhorn-system"
KUBE_CONTEXT=""
FILTER_NAMESPACE=""
FILTER_PVC=""
FILTER_CLUSTER=""
FILTER_AFTER=""
DELETE_MATCHES=false
ASSUME_YES=false
BACKUP_IDS=()

usage() {
    cat <<'EOF'
Usage: prune-longhorn-backups.sh [OPTIONS]

List or delete Longhorn Backup CRs using Longhorn's own metadata instead of
walking the NFS backupstore directly.

Filters:
  --context NAME         kubectl context to use
  --longhorn-namespace   Longhorn namespace (default: longhorn-system)
  --namespace NAME       only include backups for this Kubernetes namespace
  --pvc NAME             only include backups for this PVC name
  --cluster NAME         only include backups whose cluster label matches
  --after ISO8601        only include backups created strictly after this time
  --backup-id ID         exact backup ID to include (repeatable)

Actions:
  --delete               delete matching backups through Longhorn
  -y, --yes              skip deletion confirmation
  -h, --help             show this help

Examples:
  prune-longhorn-backups.sh --context k3s-prod --namespace factorio --pvc factorio-data
  prune-longhorn-backups.sh --context k3s-prod --backup-id backup-04931f82cedd445f --delete
  prune-longhorn-backups.sh --context k3s-prod --namespace factorio --pvc factorio-data \
    --after 2026-05-10T21:38:00-04:00 --delete
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --context)
            KUBE_CONTEXT="$2"
            shift 2
            ;;
        --longhorn-namespace)
            LONGHORN_NAMESPACE="$2"
            shift 2
            ;;
        --namespace)
            FILTER_NAMESPACE="$2"
            shift 2
            ;;
        --pvc)
            FILTER_PVC="$2"
            shift 2
            ;;
        --cluster)
            FILTER_CLUSTER="$2"
            shift 2
            ;;
        --after)
            FILTER_AFTER="$2"
            shift 2
            ;;
        --backup-id)
            BACKUP_IDS+=("$2")
            shift 2
            ;;
        --delete)
            DELETE_MATCHES=true
            shift
            ;;
        -y|--yes)
            ASSUME_YES=true
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

KUBECTL_ARGS=()
if [[ -n "$KUBE_CONTEXT" ]]; then
    KUBECTL_ARGS+=(--context "$KUBE_CONTEXT")
fi

tmp_json=$(mktemp -t longhorn-backups-XXXXXX.json)
tmp_matches=$(mktemp -t longhorn-backup-matches-XXXXXX.tsv)
trap 'rm -f "$tmp_json" "$tmp_matches"' EXIT

kubectl "${KUBECTL_ARGS[@]}" -n "$LONGHORN_NAMESPACE" get backups.longhorn.io -o json > "$tmp_json"

python3 - "$tmp_json" "$tmp_matches" "$FILTER_NAMESPACE" "$FILTER_PVC" "$FILTER_CLUSTER" "$FILTER_AFTER" "${BACKUP_IDS[@]}" <<'PY'
import json
import sys
from datetime import datetime, timezone

json_path = sys.argv[1]
out_path = sys.argv[2]
filter_namespace = sys.argv[3]
filter_pvc = sys.argv[4]
filter_cluster = sys.argv[5]
filter_after = sys.argv[6]
backup_ids = set(sys.argv[7:])


def parse_iso8601(value: str):
    if not value:
        return None
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    return datetime.fromisoformat(value).astimezone(timezone.utc)


def parse_k8s_status(raw):
    if isinstance(raw, dict):
        return raw
    if not raw:
        return {}
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return {}


with open(json_path, "r", encoding="utf-8") as fh:
    payload = json.load(fh)

after_dt = parse_iso8601(filter_after) if filter_after else None
rows = []

for item in payload.get("items", []):
    metadata = item.get("metadata") or {}
    spec = item.get("spec") or {}
    status = item.get("status") or {}
    name = metadata.get("name")
    if not name:
        continue

    labels = status.get("labels") or spec.get("labels") or {}
    k8s = parse_k8s_status(labels.get("KubernetesStatus"))
    namespace = k8s.get("namespace", "")
    pvc_name = k8s.get("pvcName", "")
    cluster = labels.get("cluster", "")
    created_at = status.get("snapshotCreatedAt") or status.get("backupCreatedAt") or ""
    state = status.get("state", "")
    url = status.get("url", "")
    volume_name = status.get("volumeName") or metadata.get("labels", {}).get("backup-volume", "")

    if backup_ids and name not in backup_ids:
        continue
    if filter_namespace and namespace != filter_namespace:
        continue
    if filter_pvc and pvc_name != filter_pvc:
        continue
    if filter_cluster and cluster != filter_cluster:
        continue
    if after_dt and created_at:
        if parse_iso8601(created_at) <= after_dt:
            continue

    rows.append((name, namespace, pvc_name, cluster, created_at, state, volume_name, url))

rows.sort(key=lambda row: (row[1], row[2], row[4], row[0]))

with open(out_path, "w", encoding="utf-8") as fh:
    for row in rows:
        fh.write("\t".join(row) + "\n")
PY

if [[ ! -s "$tmp_matches" ]]; then
    echo "No matching Longhorn backups found."
    exit 0
fi

echo "Matching Longhorn backups:"
printf '%s\n' "BACKUP_ID  NAMESPACE  PVC  CLUSTER  CREATED_AT  STATE  VOLUME"
awk -F '\t' '{ printf "%s  %s  %s  %s  %s  %s  %s\n", $1, $2, $3, $4, $5, $6, $7 }' "$tmp_matches"

if [[ "$DELETE_MATCHES" != "true" ]]; then
    exit 0
fi

if [[ "$ASSUME_YES" != "true" ]]; then
    echo
    read -r -p "Delete these backups through Longhorn? Type 'yes' to continue: " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo "Deletion cancelled."
        exit 1
    fi
fi

while IFS=$'\t' read -r backup_id _; do
    echo "Deleting backup $backup_id"
    kubectl "${KUBECTL_ARGS[@]}" -n "$LONGHORN_NAMESPACE" delete backups.longhorn.io "$backup_id"
done < "$tmp_matches"
