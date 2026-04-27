#!/usr/bin/env python3
"""
Walk a Longhorn NFS backupstore mount and emit JSON describing the latest
backup per (namespace, pvcName).

Used by ansible/playbooks/k3s-restore-from-backup.yml to drive a dynamic
restore that covers every PVC with a backup, replacing the prior static
backup_to_pvc_mapping.

The same volume.cfg / backup_*.cfg parsing logic is mirrored in
scripts/helpers/list-backups.sh; if you change the schema interpretation
here, update that too.

Usage:
  discover-backups.py <mount_point> <nfs_server> <nfs_path> [--cluster-filter prod]

Output (JSON list to stdout):
  [
    {
      "volume_name": "pvc-8b0ed227-...",
      "namespace": "vaultwarden",
      "pvc_name": "vaultwarden-data-pvc",
      "size_bytes": 104857600,
      "cluster": "prod",
      "backup_id": "backup-174dc2e6c3a24be9",
      "backup_url": "nfs://172.20.20.5:/volume1/.../...?backup=...&volume=...",
      "backup_created_at": "2025-12-28T03:00:08Z"
    },
    ...
  ]
"""
import argparse
import json
import sys
from pathlib import Path


def parse_volume_cfg(path):
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return None
    labels = data.get("Labels") or {}
    k8s_raw = labels.get("KubernetesStatus", "{}")
    try:
        k8s = json.loads(k8s_raw)
    except json.JSONDecodeError:
        k8s = {}
    return {
        "volume_dir": path.parent,
        "volume_name": data.get("Name"),
        "size_bytes": int(data.get("Size") or 0),
        "namespace": k8s.get("namespace"),
        "pvc_name": k8s.get("pvcName"),
        "cluster": labels.get("cluster"),
    }


def latest_backup(volume_dir):
    backups_dir = volume_dir / "backups"
    if not backups_dir.is_dir():
        return None
    latest = None
    for backup_cfg in backups_dir.glob("backup_*.cfg"):
        try:
            data = json.loads(backup_cfg.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        if "Name" not in data or "CreatedTime" not in data:
            continue
        if latest is None or data["CreatedTime"] > latest["CreatedTime"]:
            latest = data
    return latest


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mount_point")
    parser.add_argument("nfs_server")
    parser.add_argument("nfs_path")
    parser.add_argument(
        "--cluster-filter",
        default=None,
        help="Only include volumes whose Labels.cluster matches this value.",
    )
    args = parser.parse_args()

    backup_root = Path(args.mount_point) / "backupstore" / "volumes"
    if not backup_root.is_dir():
        print("[]")
        return

    by_pvc = {}

    for vol_cfg_path in backup_root.rglob("volume.cfg"):
        vol = parse_volume_cfg(vol_cfg_path)
        if vol is None:
            continue
        if not vol["namespace"] or not vol["pvc_name"]:
            continue
        if args.cluster_filter and vol["cluster"] != args.cluster_filter:
            continue
        backup = latest_backup(vol["volume_dir"])
        if backup is None:
            continue
        key = (vol["namespace"], vol["pvc_name"])
        existing = by_pvc.get(key)
        if existing is None or backup["CreatedTime"] > existing["backup_created_at"]:
            url = (
                f"nfs://{args.nfs_server}:{args.nfs_path}"
                f"?backup={backup['Name']}&volume={vol['volume_name']}"
            )
            by_pvc[key] = {
                "volume_name": vol["volume_name"],
                "namespace": vol["namespace"],
                "pvc_name": vol["pvc_name"],
                "size_bytes": vol["size_bytes"],
                "cluster": vol["cluster"],
                "backup_id": backup["Name"],
                "backup_url": url,
                "backup_created_at": backup["CreatedTime"],
            }

    out = sorted(by_pvc.values(), key=lambda e: (e["namespace"], e["pvc_name"]))
    print(json.dumps(out))


if __name__ == "__main__":
    main()
