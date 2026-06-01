#!/usr/bin/env bash
# Audit Longhorn volume replica placement across flash/tank disk pools.
#
# In the cross-pool architecture (see plans/i-need-some-serious-ancient-adleman.md),
# each Longhorn disk is tagged either "flash" (cheap-but-fast SSD) or "tank"
# (slow-but-robust HDD ZFS). Volumes provisioned from the default `longhorn`
# StorageClass should land one replica per pool so a flash incident leaves data
# live on tank. Volumes pinned via the fast/steady classes (`longhorn-fast` /
# `longhorn-steady`, plus legacy aliases `longhorn-flash` / `longhorn-tank`)
# are expected to be all-on-one-pool by design and skipped.
#
# This script:
#  1. Walks every Longhorn Volume in longhorn-system.
#  2. Resolves each volume's PVC and its StorageClass (skips pinned fast/steady classes).
#  3. For each replica, looks up which disk it's on and the disk's tags.
#  4. Flags volumes where all replicas sit on the same pool (flash-only or
#     tank-only) when the SC is the default `longhorn`.
#  5. Prints a one-shot repair command per flagged volume.
#
# Exit codes:
#   0  no misplaced volumes
#   1  one or more misplaced (audit fail)
#   2  prerequisite missing (kubectl/jq not found, no kubeconfig, etc.)

set -uo pipefail

KUBECTL=${KUBECTL:-kubectl}
JQ=${JQ:-jq}
NS=longhorn-system

for cmd in "$KUBECTL" "$JQ"; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "missing $cmd in PATH" >&2; exit 2; }
done
"$KUBECTL" cluster-info >/dev/null 2>&1 || { echo "no working kubeconfig" >&2; exit 2; }

# Build disk-id → pool-tag lookup ("flash" | "tank" | "untagged")
# Tags live in spec.disks; UUID lives in status.diskStatus. Join by disk-name.
disk_pool_map=$("$KUBECTL" -n "$NS" get node.longhorn.io -o json | "$JQ" -r '
  [ .items[]
    | .spec.disks as $specs
    | .status.diskStatus | to_entries[]
    | { id: .value.diskUUID, tags: ($specs[.key].tags // []) }
  ]
  | map(select(.id != null and .id != ""))
  | map({
      key: .id,
      value: ( if   any(.tags[]; . == "flash") then "flash"
               elif any(.tags[]; . == "tank")  then "tank"
               else "untagged"
               end )
    })
  | from_entries
')

# Pull all volumes + their PVC info in one shot
volumes_json=$("$KUBECTL" -n "$NS" get volume.longhorn.io -o json)
replicas_json=$("$KUBECTL" -n "$NS" get replica.longhorn.io -o json)

flagged=0
checked=0
skipped_sc=0

while IFS=$'\t' read -r vol pvc_ns pvc_name; do
  [ -z "$vol" ] && continue
  checked=$((checked + 1))

  # Resolve StorageClass of the PVC. Default to "" if PVC not found.
  if [ -n "$pvc_ns" ] && [ -n "$pvc_name" ]; then
    sc=$("$KUBECTL" -n "$pvc_ns" get pvc "$pvc_name" -o jsonpath='{.spec.storageClassName}' 2>/dev/null || echo "")
  else
    sc=""
  fi

  if [ "$sc" = "longhorn-flash" ] || [ "$sc" = "longhorn-tank" ] || \
     [ "$sc" = "longhorn-fast" ] || [ "$sc" = "longhorn-steady" ]; then
    skipped_sc=$((skipped_sc + 1))
    continue
  fi

  # Collect this volume's replica disk-ids
  replica_disks=$(echo "$replicas_json" | "$JQ" -r --arg v "$vol" '
    [ .items[] | select(.spec.volumeName == $v) | .spec.diskID ] | .[]
  ')

  pools=()
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    p=$(echo "$disk_pool_map" | "$JQ" -r --arg k "$d" '.[$k] // "unknown"')
    pools+=("$p")
  done <<< "$replica_disks"

  if [ ${#pools[@]} -lt 2 ]; then
    # Less than 2 replicas — not a cross-pool concern; could be a 1-replica volume
    continue
  fi

  unique_pools=$(printf "%s\n" "${pools[@]}" | sort -u | tr '\n' ',' | sed 's/,$//')
  if [[ "$unique_pools" == "flash" ]] || [[ "$unique_pools" == "tank" ]]; then
    flagged=$((flagged + 1))
    printf "MISPLACED %-50s sc=%-10s pools=[%s] replicas=[%s]\n" \
      "$vol" "${sc:-<no-pvc>}" "$unique_pools" "$(printf "%s," "${pools[@]}" | sed 's/,$//')"
    # Repair hint: delete one replica from the over-represented pool; Longhorn
    # will rebuild. For deterministic cross-pool placement, see the runbook in
    # plans/i-need-some-serious-ancient-adleman.md Phase 6 (temporarily set
    # allowScheduling=false on the over-represented pool's disks while the
    # rebuild happens).
    while IFS=$'\t' read -r rname rdisk; do
      pool=$(echo "$disk_pool_map" | "$JQ" -r --arg k "$rdisk" '.[$k] // "unknown"')
      printf "  → replica %s on disk %s (pool=%s)\n" "$rname" "${rdisk:0:8}" "$pool"
    done < <(echo "$replicas_json" | "$JQ" -r --arg v "$vol" '
      .items[] | select(.spec.volumeName == $v) | "\(.metadata.name)\t\(.spec.diskID)"
    ')
    echo
  fi
done < <(echo "$volumes_json" | "$JQ" -r '
  .items[]
  | "\(.metadata.name)\t\(.status.kubernetesStatus.namespace // "")\t\(.status.kubernetesStatus.pvcName // "")"
')

echo
echo "Checked: $checked volumes (skipped $skipped_sc on flash/tank SC)"
echo "Misplaced: $flagged"

[ "$flagged" -eq 0 ] && exit 0 || exit 1
