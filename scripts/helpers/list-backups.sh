#!/bin/bash
# =============================================================================
# List Available Longhorn Backups
# =============================================================================
# Quick script to list all available Longhorn backups from NFS storage.
#
# Usage:
#   ./list_backups.sh              # List backups (summary, deduplicated)
#   ./list_backups.sh --detailed   # Show individual backup timestamps
#   ./list_backups.sh --all        # Show all volume instances (not deduplicated)
# =============================================================================

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
NFS_SERVER="172.20.20.5"
NFS_PATH="/volume1/k3s-storage/longhorn/shared"
MOUNT_POINT="/tmp/longhorn-backup-list"
SSH_HOST="k3s-prod-node-1"
DETAILED=false
SHOW_ALL=false

# Parse args
while [[ $# -gt 0 ]]; do
    case $1 in
        --detailed|-d)
            DETAILED=true
            shift
            ;;
        --all|-a)
            SHOW_ALL=true
            shift
            ;;
        *)
            shift
            ;;
    esac
done

echo -e "${BLUE}======================================================${NC}"
echo -e "${BLUE}  Available Longhorn Backups${NC}"
echo -e "${BLUE}======================================================${NC}"
echo ""

# Run the listing on the cluster node using Python for reliable JSON parsing
ssh "$SSH_HOST" bash -s "$NFS_SERVER" "$NFS_PATH" "$MOUNT_POINT" "$DETAILED" "$SHOW_ALL" << 'REMOTE_SCRIPT'
NFS_SERVER="$1"
NFS_PATH="$2"
MOUNT_POINT="$3"
DETAILED="$4"
SHOW_ALL="$5"

# Mount NFS
sudo mkdir -p "$MOUNT_POINT"
sudo mount -t nfs -o ro "$NFS_SERVER:$NFS_PATH" "$MOUNT_POINT" 2>/dev/null || true

cleanup() {
    sudo umount "$MOUNT_POINT" 2>/dev/null || true
    sudo rmdir "$MOUNT_POINT" 2>/dev/null || true
}
trap cleanup EXIT

BACKUP_ROOT="$MOUNT_POINT/backupstore/volumes"

if [ ! -d "$BACKUP_ROOT" ]; then
    echo "No backups found at $BACKUP_ROOT"
    exit 0
fi

# Use Python for reliable JSON parsing
python3 << PYTHON_SCRIPT
import os
import json
from pathlib import Path
from datetime import datetime
from collections import defaultdict

backup_root = "$BACKUP_ROOT"
detailed = "$DETAILED" == "true"
show_all = "$SHOW_ALL" == "true"

volumes = []

# Find all volume.cfg files
for volume_cfg in Path(backup_root).rglob("volume.cfg"):
    volume_dir = volume_cfg.parent
    backup_dir = volume_dir / "backups"

    try:
        with open(volume_cfg) as f:
            vol_data = json.load(f)

        volume_name = vol_data.get("Name", "unknown")
        labels = vol_data.get("Labels", {})

        # Parse KubernetesStatus (it's a JSON string inside Labels)
        k8s_status_str = labels.get("KubernetesStatus", "{}")
        try:
            k8s_status = json.loads(k8s_status_str)
            namespace = k8s_status.get("namespace", "unknown")
            pvc_name = k8s_status.get("pvcName", volume_name)
        except:
            namespace = "unknown"
            pvc_name = volume_name

        cluster = labels.get("cluster", "prod")

        # Get backup info
        backups = []
        if backup_dir.exists():
            for backup_file in backup_dir.glob("backup_*.cfg"):
                try:
                    with open(backup_file) as f:
                        backup_data = json.load(f)
                    backups.append({
                        "name": backup_data.get("Name", "unknown"),
                        "created": backup_data.get("CreatedTime", ""),
                        "size": int(backup_data.get("Size", 0))
                    })
                except:
                    pass

        if backups:
            # Sort by created time (newest first)
            backups.sort(key=lambda x: x["created"], reverse=True)
            latest = backups[0]["created"]

            volumes.append({
                "namespace": namespace,
                "pvc_name": pvc_name,
                "volume_name": volume_name,
                "cluster": cluster,
                "backup_count": len(backups),
                "latest": latest,
                "backups": backups
            })
    except Exception as e:
        pass

# Sort by latest backup time (newest first), then by namespace, pvc_name
volumes.sort(key=lambda x: (x["namespace"], x["pvc_name"], x["latest"]), reverse=False)

# Deduplicate: keep only the entry with the most recent backup per namespace/pvc_name
if not show_all:
    deduped = {}
    for vol in volumes:
        key = (vol["namespace"], vol["pvc_name"])
        if key not in deduped or vol["latest"] > deduped[key]["latest"]:
            # Merge backup counts for display
            if key in deduped:
                vol["backup_count"] += deduped[key]["backup_count"]
                vol["backups"] = sorted(vol["backups"] + deduped[key]["backups"],
                                       key=lambda x: x["created"], reverse=True)
            deduped[key] = vol
    volumes = list(deduped.values())
    volumes.sort(key=lambda x: (x["namespace"], x["pvc_name"]))

# Print results
current_ns = None
total_backups = 0
for vol in volumes:
    if vol["namespace"] != current_ns:
        if current_ns is not None:
            print()
        print(f"\033[1;36m{vol['namespace']}\033[0m")
        current_ns = vol["namespace"]

    # Format the latest time nicely
    try:
        dt = datetime.fromisoformat(vol["latest"].replace("Z", "+00:00"))
        latest_fmt = dt.strftime("%Y-%m-%d %H:%M")
    except:
        latest_fmt = vol["latest"]

    total_backups += vol["backup_count"]
    suffix = ""
    if show_all and vol.get("cluster"):
        suffix = f" [{vol['cluster']}]"

    print(f"  {vol['pvc_name']:<40} ({vol['backup_count']:>2} backups, latest: {latest_fmt}){suffix}")

    if detailed:
        shown = 0
        for backup in vol["backups"][:5]:  # Show max 5 in detailed mode
            try:
                dt = datetime.fromisoformat(backup["created"].replace("Z", "+00:00"))
                created_fmt = dt.strftime("%Y-%m-%d %H:%M")
            except:
                created_fmt = backup["created"]
            size_mb = backup["size"] // (1024 * 1024)
            print(f"      └─ {backup['name']:<35} {created_fmt} ({size_mb} MB)")
            shown += 1
        if len(vol["backups"]) > 5:
            print(f"      ... and {len(vol['backups']) - 5} more backups")

print()
print(f"\033[1mTotal: {len(volumes)} PVCs with {total_backups} backups\033[0m")
PYTHON_SCRIPT
REMOTE_SCRIPT

echo ""
echo -e "${YELLOW}Options:${NC}"
echo "  --detailed  Show individual backup timestamps"
echo "  --all       Show all volume instances (including old cluster data)"
echo ""
echo -e "${GREEN}To restore backups, use:${NC}"
echo "  ./restore_cluster.sh --stage --from prod    # Clone prod to stage"
echo "  ./restore_cluster.sh --prod --restore-only  # Restore to existing prod"
echo "  ./restore_cluster.sh --prod --app bookstack # Restore specific app"
