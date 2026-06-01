#!/usr/bin/env bash
# Audit Longhorn PVCs against the explicit storage policy inventory.

set -uo pipefail

KUBECTL=${KUBECTL:-kubectl}
JQ=${JQ:-jq}
LONGHORN_NS=longhorn-system
INVENTORY_FILE=${INVENTORY_FILE:-$(dirname "$0")/storage-policy-inventory.tsv}
PRIVATE_INVENTORY_FILE=${PRIVATE_INVENTORY_FILE:-$HOME/.config/home-infra/storage-policy-private.tsv}

for cmd in "$KUBECTL" "$JQ"; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "missing $cmd in PATH" >&2; exit 2; }
done

[ -f "$INVENTORY_FILE" ] || { echo "missing inventory file: $INVENTORY_FILE" >&2; exit 2; }
"$KUBECTL" cluster-info >/dev/null 2>&1 || { echo "no working kubeconfig" >&2; exit 2; }

declare -A EXPECTED_SC EXPECTED_REPLICAS EXPECTED_BACKUPS
declare -A LIVE_PVC ACTUAL_SC ACTUAL_BACKUPS
declare -A LIVE_LONGHORN_PVC
declare -A LIVE_LONGHORN ACTUAL_VOLUME ACTUAL_REPLICAS ACTUAL_DISK_SELECTOR

backup_string() {
  local hourly="$1" daily="$2" weekly="$3"
  local parts=()
  [ "$hourly" = "enabled" ] && parts+=(hourly)
  [ "$daily" = "enabled" ] && parts+=(daily)
  [ "$weekly" = "enabled" ] && parts+=(weekly)
  if [ ${#parts[@]} -eq 0 ]; then
    printf "none"
  else
    local joined
    joined=$(IFS=,; printf "%s" "${parts[*]}")
    printf "%s" "$joined"
  fi
}

expected_disk_selector() {
  case "$1" in
    longhorn-fast|longhorn-flash) printf "flash" ;;
    longhorn-steady|longhorn-tank) printf "tank" ;;
    *) printf "none" ;;
  esac
}

status_cell() {
  local expected="$1" actual="$2"
  if [ "$expected" = "$actual" ]; then
    printf "✅ %s" "$actual"
  else
    printf "❌ %s -> %s" "$expected" "$actual"
  fi
}

load_inventory() {
  while IFS=$'\t' read -r namespace pvc expected_sc expected_replicas expected_backups; do
    [ -z "$namespace" ] && continue
    case "$namespace" in
      \#*) continue ;;
    esac

    local key="$namespace/$pvc"
    EXPECTED_SC["$key"]="$expected_sc"
    EXPECTED_REPLICAS["$key"]="$expected_replicas"
    EXPECTED_BACKUPS["$key"]="$expected_backups"
  done < "$INVENTORY_FILE"

  if [ -f "$PRIVATE_INVENTORY_FILE" ]; then
    while IFS=$'\t' read -r namespace pvc expected_sc expected_replicas expected_backups; do
      [ -z "$namespace" ] && continue
      case "$namespace" in
        \#*) continue ;;
      esac

      local key="$namespace/$pvc"
      EXPECTED_SC["$key"]="$expected_sc"
      EXPECTED_REPLICAS["$key"]="$expected_replicas"
      EXPECTED_BACKUPS["$key"]="$expected_backups"
    done < "$PRIVATE_INVENTORY_FILE"
  fi
}

load_live_state() {
  while IFS=$'\x1f' read -r namespace pvc sc hourly daily weekly; do
    local key="$namespace/$pvc"
    LIVE_PVC["$key"]=1
    ACTUAL_SC["$key"]="$sc"
    ACTUAL_BACKUPS["$key"]=$(backup_string "$hourly" "$daily" "$weekly")
    case "$sc" in
      longhorn*) LIVE_LONGHORN_PVC["$key"]=1 ;;
    esac
  done < <(
    "$KUBECTL" get pvc -A -o json | "$JQ" -r '
      .items[]
      | [
          .metadata.namespace,
          .metadata.name,
          (.spec.storageClassName // ""),
          (.metadata.labels["recurring-job-group.longhorn.io/hourly"] // ""),
          (.metadata.labels["recurring-job-group.longhorn.io/daily"] // ""),
          (.metadata.labels["recurring-job-group.longhorn.io/weekly"] // "")
        ]
      | @tsv
      | gsub("\t"; "\u001f")'
  )

  while IFS=$'\x1f' read -r namespace pvc volume replicas disk_selector; do
    local key="$namespace/$pvc"
    LIVE_LONGHORN["$key"]=1
    ACTUAL_VOLUME["$key"]="$volume"
    ACTUAL_REPLICAS["$key"]="$replicas"
    ACTUAL_DISK_SELECTOR["$key"]="${disk_selector:-none}"
  done < <(
    "$KUBECTL" -n "$LONGHORN_NS" get volume.longhorn.io -o json | "$JQ" -r '
      .items[]
      | [
          (.status.kubernetesStatus.namespace // ""),
          (.status.kubernetesStatus.pvcName // ""),
          .metadata.name,
          (.spec.numberOfReplicas | tostring),
          ((.spec.diskSelector // []) | join(","))
        ]
      | @tsv
      | gsub("\t"; "\u001f")'
  )
}

load_inventory
load_live_state

echo "| PVC | StorageClass | Replicas | Backup groups | Runtime patch |"
echo "| --- | --- | --- | --- | --- |"

inventory_count=0
covered_count=0
live_longhorn_pvc_count=0
passing_count=0
failing_count=0
uncovered_count=0
orphan_count=0

while IFS= read -r key; do
  inventory_count=$((inventory_count + 1))
  expected_sc="${EXPECTED_SC[$key]}"
  expected_replicas="${EXPECTED_REPLICAS[$key]}"
  expected_backups="${EXPECTED_BACKUPS[$key]}"
  expected_selector=$(expected_disk_selector "$expected_sc")

  actual_sc="${ACTUAL_SC[$key]:-missing}"
  actual_replicas="${ACTUAL_REPLICAS[$key]:-missing}"
  actual_backups="${ACTUAL_BACKUPS[$key]:-missing}"
  actual_selector="${ACTUAL_DISK_SELECTOR[$key]:-missing}"
  [ "$actual_selector" = "" ] && actual_selector="none"

  if [ -n "${LIVE_LONGHORN_PVC[$key]:-}" ]; then
    covered_count=$((covered_count + 1))
  fi

  row_failed=0
  [ "$expected_sc" = "$actual_sc" ] || row_failed=1
  [ "$expected_replicas" = "$actual_replicas" ] || row_failed=1
  [ "$expected_backups" = "$actual_backups" ] || row_failed=1
  [ "$expected_selector" = "$actual_selector" ] || row_failed=1

  if [ "$row_failed" -eq 0 ]; then
    passing_count=$((passing_count + 1))
  else
    failing_count=$((failing_count + 1))
  fi

  printf '| `%s` | %s | %s | %s | %s |\n' \
    "$key" \
    "$(status_cell "$expected_sc" "$actual_sc")" \
    "$(status_cell "$expected_replicas" "$actual_replicas")" \
    "$(status_cell "$expected_backups" "$actual_backups")" \
    "$(status_cell "$expected_selector" "$actual_selector")"
done < <(printf '%s\n' "${!EXPECTED_SC[@]}" | sort)

echo

for key in "${!LIVE_LONGHORN_PVC[@]}"; do
  live_longhorn_pvc_count=$((live_longhorn_pvc_count + 1))
  if [ -z "${EXPECTED_SC[$key]:-}" ]; then
    uncovered_count=$((uncovered_count + 1))
  fi
done

for key in "${!LIVE_LONGHORN[@]}"; do
  if [ -z "${LIVE_PVC[$key]:-}" ]; then
    orphan_count=$((orphan_count + 1))
  fi
done

echo "Summary:"
echo "- Inventory rows: $inventory_count"
echo "- Live Longhorn PVCs: $live_longhorn_pvc_count"
echo "- Live Longhorn PVCs covered by inventory: $covered_count"
echo "- Passing rows: $passing_count"
echo "- Failing rows: $failing_count"
echo "- Uncovered live Longhorn PVCs: $uncovered_count"
echo "- Longhorn volumes without a live PVC: $orphan_count"

if [ "$uncovered_count" -gt 0 ]; then
  echo
  echo "Uncovered live Longhorn PVCs:"
  for key in "${!LIVE_LONGHORN[@]}"; do
    [ -n "${EXPECTED_SC[$key]:-}" ] && continue
    [ -z "${LIVE_PVC[$key]:-}" ] && continue
    echo "- $key"
  done
fi

if [ "$orphan_count" -gt 0 ]; then
  echo
  echo "Longhorn volumes without a live PVC:"
  for key in "${!LIVE_LONGHORN[@]}"; do
    [ -n "${LIVE_PVC[$key]:-}" ] && continue
    echo "- $key (volume=${ACTUAL_VOLUME[$key]:-unknown})"
  done
fi

if [ "$failing_count" -eq 0 ] && [ "$uncovered_count" -eq 0 ] && [ "$orphan_count" -eq 0 ]; then
  exit 0
fi

exit 1
