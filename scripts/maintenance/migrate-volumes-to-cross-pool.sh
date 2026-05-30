#!/usr/bin/env bash
# Migrate Longhorn volumes whose replicas are all on one disk-pool to a
# cross-pool (flash + tank) layout.
#
# Strategy per volume:
#   1. Bump numberOfReplicas from 2 → 3 → Longhorn schedules the 3rd replica.
#      With the over-represented pool's disks loaded and the other pool nearly
#      empty, the new replica goes to the under-represented pool.
#   2. Wait for the volume to be healthy at 3 replicas.
#   3. Drop numberOfReplicas back to 2 → Longhorn drops one extra. Anti-affinity
#      preferences keep the cross-pool pair when possible.
#   4. Confirm with the audit script that this volume is now cross-pool.
#
# When step 1 keeps placing the new replica on the over-represented pool,
# rerun this script with --force-tank or --force-flash to temporarily disable
# scheduling on the over-represented pool's disks for the bump.
#
# Usage:
#   migrate-volumes-to-cross-pool.sh                 # process all misplaced
#   migrate-volumes-to-cross-pool.sh <vol> [<vol>]   # specific volumes
#   migrate-volumes-to-cross-pool.sh --dry-run       # show planned actions
#   migrate-volumes-to-cross-pool.sh --force-tank    # disable flash scheduling
#                                                     during bump (use when
#                                                     all current replicas
#                                                     are flash-only)
#   migrate-volumes-to-cross-pool.sh --force-flash   # opposite

set -uo pipefail

KUBECTL=${KUBECTL:-kubectl}
JQ=${JQ:-jq}
NS=longhorn-system

DRY_RUN=0
FORCE_DIR=""
TARGETS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --force-tank) FORCE_DIR=tank; shift ;;
    --force-flash) FORCE_DIR=flash; shift ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    -*)
      echo "unknown flag: $1" >&2; exit 2 ;;
    *)
      TARGETS+=("$1"); shift ;;
  esac
done

for cmd in "$KUBECTL" "$JQ"; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "missing $cmd in PATH" >&2; exit 2; }
done

# Build disk-id → pool map
disk_pool_map() {
  "$KUBECTL" -n "$NS" get node.longhorn.io -o json | "$JQ" -r '
    [ .items[] | .spec.disks as $specs | .status.diskStatus | to_entries[]
      | { id: .value.diskUUID, tags: ($specs[.key].tags // []) } ]
    | map(select(.id != null and .id != ""))
    | map({ key: .id, value: ( if any(.tags[]; . == "flash") then "flash"
                               elif any(.tags[]; . == "tank") then "tank"
                               else "untagged" end )})
    | from_entries'
}

# Identify volumes that are not cross-pool (replicas all on flash or all on tank,
# excluding volumes whose StorageClass explicitly pins to one pool).
list_misplaced() {
  local pool_map; pool_map=$(disk_pool_map)
  "$KUBECTL" -n "$NS" get volumes -o json | "$JQ" -r --argjson dp "$pool_map" '
    .items[]
    | { name: .metadata.name,
        ns: (.status.kubernetesStatus.namespace // ""),
        pvc: (.status.kubernetesStatus.pvcName // "") }
    | "\(.name)\t\(.ns)\t\(.pvc)"' | while IFS=$'\t' read -r vol pvc_ns pvc_name; do
      [ -z "$vol" ] && continue
      sc=""
      if [ -n "$pvc_ns" ] && [ -n "$pvc_name" ]; then
        sc=$("$KUBECTL" -n "$pvc_ns" get pvc "$pvc_name" -o jsonpath='{.spec.storageClassName}' 2>/dev/null || true)
      fi
      [ "$sc" = "longhorn-flash" ] && continue
      [ "$sc" = "longhorn-tank" ] && continue
      pools=$("$KUBECTL" -n "$NS" get replicas -o json | "$JQ" -r --arg v "$vol" '
        [ .items[] | select(.spec.volumeName == $v) | .spec.diskID ] | .[]' | while read -r d; do
          [ -n "$d" ] && echo "$pool_map" | "$JQ" -r --arg k "$d" '.[$k] // "?"'
        done | sort -u | tr '\n' ',' | sed 's/,$//')
      if [ "$pools" = "flash" ] || [ "$pools" = "tank" ]; then
        echo "$vol"
      fi
    done
}

# Set allowScheduling on every disk with a given tag.
set_pool_scheduling() {
  local tag="$1" allow="$2"
  "$KUBECTL" -n "$NS" get node.longhorn.io -o json | "$JQ" -r --arg t "$tag" '
    .items[] as $n
    | $n.spec.disks | to_entries[]
    | select(.value.tags | index($t))
    | "\($n.metadata.name)\t\(.key)"' | while IFS=$'\t' read -r node disk; do
      [ -z "$node" ] && continue
      "$KUBECTL" -n "$NS" patch node.longhorn.io "$node" --type=json \
        -p="[{\"op\":\"replace\",\"path\":\"/spec/disks/$disk/allowScheduling\",\"value\":$allow}]" \
        >/dev/null
      echo "  $node/$disk allowScheduling=$allow"
    done
}

wait_volume_replicas() {
  local vol="$1" expected="$2" timeout="${3:-300}"
  local elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    local healthy
    healthy=$("$KUBECTL" -n "$NS" get replicas -o json | "$JQ" -r --arg v "$vol" '
      [ .items[] | select(.spec.volumeName == $v and (.status.currentState // "") == "running") ] | length')
    if [ "$healthy" -ge "$expected" ]; then
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  return 1
}

migrate_one() {
  local vol="$1"
  echo "==== Migrating $vol ===="

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  (dry-run) bump $vol numberOfReplicas → 3, wait, drop → 2"
    return 0
  fi

  echo "  Bump to 3 replicas"
  "$KUBECTL" -n "$NS" patch volume "$vol" --type=merge -p '{"spec":{"numberOfReplicas":3}}' >/dev/null

  echo "  Waiting for 3 healthy replicas..."
  if ! wait_volume_replicas "$vol" 3 300; then
    echo "  TIMEOUT — volume did not reach 3 healthy replicas in 5 min"
    return 1
  fi

  echo "  Drop back to 2 replicas"
  "$KUBECTL" -n "$NS" patch volume "$vol" --type=merge -p '{"spec":{"numberOfReplicas":2}}' >/dev/null

  echo "  Waiting for 2 healthy replicas..."
  if ! wait_volume_replicas "$vol" 2 120; then
    echo "  TIMEOUT — volume did not settle at 2 healthy replicas"
    return 1
  fi

  echo "  Done."
}

# Main
if [ ${#TARGETS[@]} -eq 0 ]; then
  echo "Discovering misplaced volumes..."
  while read -r v; do
    [ -n "$v" ] && TARGETS+=("$v")
  done < <(list_misplaced)
fi

if [ ${#TARGETS[@]} -eq 0 ]; then
  echo "Nothing to migrate. All non-pinned volumes are already cross-pool."
  exit 0
fi

echo "Will migrate ${#TARGETS[@]} volume(s):"
printf "  - %s\n" "${TARGETS[@]}"
echo

if [ -n "$FORCE_DIR" ] && [ "$DRY_RUN" -eq 0 ]; then
  # When forcing toward tank, we disable scheduling on flash; vice versa.
  off_pool=$([ "$FORCE_DIR" = "tank" ] && echo flash || echo tank)
  echo "Disabling scheduling on $off_pool disks (force toward $FORCE_DIR)..."
  set_pool_scheduling "$off_pool" false
  trap 'echo "Re-enabling scheduling on '"$off_pool"' disks..."; set_pool_scheduling '"$off_pool"' true' EXIT
fi

failed=0
for v in "${TARGETS[@]}"; do
  if ! migrate_one "$v"; then
    failed=$((failed + 1))
  fi
  echo
done

echo "Migrated successfully: $((${#TARGETS[@]} - failed))"
echo "Failed: $failed"
[ "$failed" -eq 0 ]
