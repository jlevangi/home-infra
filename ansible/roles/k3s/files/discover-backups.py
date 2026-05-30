#!/usr/bin/env python3
"""
Emit JSON describing the latest eligible Longhorn backup per (namespace, pvcName).

Discovery modes:
  - nfs-scan: walk a mounted Longhorn NFS backupstore directly
  - longhorn-cr: query Longhorn BackupVolume / Backup CRs through kubectl

Usage:
  discover-backups.py <mount_point> <nfs_server> <nfs_path> [--cluster-filter prod]
  discover-backups.py --mode longhorn-cr --kubeconfig /etc/rancher/k3s/k3s.yaml
  discover-backups.py --mode longhorn-cr --backup-before 2026-05-11

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
    }
  ]
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse


def load_json_file(path: Path) -> dict[str, Any] | None:
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return None


def parse_kubernetes_status(raw: Any) -> dict[str, Any]:
    if isinstance(raw, dict):
        return raw
    if not raw:
        return {}
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return {}


def parse_timestamp(raw: Any) -> datetime | None:
    if raw is None:
        return None
    if isinstance(raw, datetime):
        return raw.astimezone(timezone.utc)
    if isinstance(raw, (int, float)):
        return datetime.fromtimestamp(raw, tz=timezone.utc)
    if not isinstance(raw, str):
        return None

    value = raw.strip()
    if not value:
        return None
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def format_timestamp(value: datetime | None) -> str | None:
    if value is None:
        return None
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def parse_volume_cfg(path: Path) -> dict[str, Any] | None:
    data = load_json_file(path)
    if data is None:
        return None

    labels = data.get("Labels") or {}
    k8s = parse_kubernetes_status(labels.get("KubernetesStatus"))

    return {
        "volume_dir": path.parent,
        "volume_name": data.get("Name"),
        "size_bytes": int(data.get("Size") or 0),
        "namespace": k8s.get("namespace"),
        "pvc_name": k8s.get("pvcName"),
        "cluster": labels.get("cluster"),
    }


def backup_matches_filters(backup_id: str, created_at: datetime | None, args: argparse.Namespace) -> bool:
    if args.backup_id and backup_id != args.backup_id:
        return False
    if args.backup_before_dt and created_at and created_at >= args.backup_before_dt:
        return False
    return True


def latest_backup_from_nfs(volume_dir: Path, args: argparse.Namespace) -> dict[str, Any] | None:
    backups_dir = volume_dir / "backups"
    if not backups_dir.is_dir():
        return None

    latest = None
    latest_created_at: datetime | None = None
    for backup_cfg in backups_dir.glob("backup_*.cfg"):
        data = load_json_file(backup_cfg)
        if data is None:
            continue
        if "Name" not in data or "CreatedTime" not in data:
            continue
        created_at = parse_timestamp(data["CreatedTime"])
        if not backup_matches_filters(str(data["Name"]), created_at, args):
            continue
        if created_at is None:
            continue
        if latest is None or created_at > latest_created_at or (
            created_at == latest_created_at and str(data["Name"]) > str(latest["Name"])
        ):
            latest = data
            latest_created_at = created_at
    return latest


def discover_from_nfs(args: argparse.Namespace) -> list[dict[str, Any]]:
    backup_root = Path(args.mount_point) / "backupstore" / "volumes"
    if not backup_root.is_dir():
        return []

    by_pvc: dict[tuple[str, str], dict[str, Any]] = {}

    for vol_cfg_path in backup_root.rglob("volume.cfg"):
        vol = parse_volume_cfg(vol_cfg_path)
        if vol is None:
            continue
        if not vol["namespace"] or not vol["pvc_name"]:
            continue
        if args.cluster_filter and vol["cluster"] != args.cluster_filter:
            continue

        backup = latest_backup_from_nfs(vol["volume_dir"], args)
        if backup is None:
            continue

        backup_created_at = format_timestamp(parse_timestamp(backup["CreatedTime"]))
        if backup_created_at is None:
            continue

        key = (vol["namespace"], vol["pvc_name"])
        existing = by_pvc.get(key)
        if existing is None or backup_created_at > existing["backup_created_at"]:
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
                "backup_created_at": backup_created_at,
            }

    return sorted(by_pvc.values(), key=lambda e: (e["namespace"], e["pvc_name"]))


def run_kubectl_json(kubeconfig: str, longhorn_namespace: str, resource: str) -> dict[str, Any]:
    cmd = [
        "kubectl",
        "--kubeconfig",
        kubeconfig,
        "-n",
        longhorn_namespace,
        "get",
        resource,
        "-o",
        "json",
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        print(result.stderr.strip(), file=sys.stderr)
        raise SystemExit(result.returncode)
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"failed to parse kubectl output for {resource}: {exc}") from exc


def parse_size_bytes(raw: Any) -> int:
    if raw is None:
        return 0
    if isinstance(raw, int):
        return raw
    if isinstance(raw, str):
        try:
            return int(raw)
        except ValueError:
            return 0
    return 0


def parse_volume_name_from_url(url: str) -> str:
    query = parse_qs(urlparse(url).query)
    return query.get("volume", [""])[0]


def discover_from_longhorn_cr(args: argparse.Namespace) -> list[dict[str, Any]]:
    backups = run_kubectl_json(
        args.kubeconfig,
        args.longhorn_namespace,
        "backups.longhorn.io",
    )

    by_pvc: dict[tuple[str, str], dict[str, Any]] = {}
    ambiguous: list[str] = []

    for item in backups.get("items", []):
        metadata = item.get("metadata") or {}
        status = item.get("status") or {}
        spec = item.get("spec") or {}
        labels = status.get("labels") or spec.get("labels") or metadata.get("labels") or {}
        k8s = parse_kubernetes_status(labels.get("KubernetesStatus"))
        namespace = k8s.get("namespace")
        pvc_name = k8s.get("pvcName")
        cluster = labels.get("cluster")
        backup_id = metadata.get("name")
        backup_created_at = parse_timestamp(
            status.get("backupCreatedAt")
            or status.get("snapshotCreatedAt")
            or metadata.get("creationTimestamp")
        )

        if not namespace or not pvc_name or not backup_id or backup_created_at is None:
            continue
        if args.cluster_filter and cluster != args.cluster_filter:
            continue

        if not backup_matches_filters(backup_id, backup_created_at, args):
            continue

        backup_url = status.get("url")
        if not backup_url:
            # Skip backups that don't have a URL yet (CR was created but
            # backup never finished or is stuck mid-Deleting). Don't fail
            # the whole discovery on one bad backup.
            continue

        volume_name = parse_volume_name_from_url(backup_url) or status.get("volumeName") or ""
        record = {
            "volume_name": volume_name,
            "namespace": namespace,
            "pvc_name": pvc_name,
            # Longhorn `status.size` is the *incremental* backup delta, not the
            # volume size. For restore we always need the original volume size
            # so the destination Volume + PV/PVC are sized correctly; use
            # `status.volumeSize` first and fall back to `status.size` only if
            # volumeSize is missing.
            "size_bytes": parse_size_bytes(status.get("volumeSize"))
                          or parse_size_bytes(status.get("size")),
            "cluster": cluster,
            "backup_id": backup_id,
            "backup_url": backup_url,
            "backup_created_at": format_timestamp(backup_created_at),
        }

        key = (namespace, pvc_name)
        existing = by_pvc.get(key)
        if existing is None:
            by_pvc[key] = record
            continue

        if record["backup_created_at"] > existing["backup_created_at"]:
            by_pvc[key] = record
        elif record["backup_created_at"] == existing["backup_created_at"]:
            ambiguous.append(
                f"{namespace}/{pvc_name}: {existing['backup_id']} vs {record['backup_id']}"
            )

    if ambiguous:
        joined = "; ".join(sorted(ambiguous))
        raise SystemExit(f"ambiguous latest backups discovered: {joined}")

    return sorted(by_pvc.values(), key=lambda e: (e["namespace"], e["pvc_name"]))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("mount_point", nargs="?")
    parser.add_argument("nfs_server", nargs="?")
    parser.add_argument("nfs_path", nargs="?")
    parser.add_argument(
        "--mode",
        choices=["nfs-scan", "longhorn-cr"],
        default=None,
        help="Discovery mode. Defaults to nfs-scan for legacy positional usage.",
    )
    parser.add_argument(
        "--cluster-filter",
        default=None,
        help="Only include volumes whose cluster label matches this value.",
    )
    parser.add_argument(
        "--backup-before",
        default=None,
        help="Only include backups strictly older than this ISO timestamp or date (for example 2026-05-11 or 2026-05-11T00:00:00Z).",
    )
    parser.add_argument(
        "--backup-id",
        default=None,
        help="Only include this exact backup ID (for example backup-1234).",
    )
    parser.add_argument(
        "--kubeconfig",
        default="/etc/rancher/k3s/k3s.yaml",
        help="Kubeconfig path used for longhorn-cr discovery.",
    )
    parser.add_argument(
        "--longhorn-namespace",
        default="longhorn-system",
        help="Namespace containing Longhorn BackupVolume and Backup CRs.",
    )
    return parser


def validate_args(args: argparse.Namespace) -> str:
    mode = args.mode
    if mode is None:
        mode = "nfs-scan" if args.mount_point else "longhorn-cr"

    if mode == "nfs-scan" and not all([args.mount_point, args.nfs_server, args.nfs_path]):
        raise SystemExit("nfs-scan mode requires <mount_point> <nfs_server> <nfs_path>")

    args.backup_before_dt = parse_timestamp(args.backup_before)
    if args.backup_before and args.backup_before_dt is None:
        raise SystemExit(f"invalid --backup-before timestamp: {args.backup_before}")

    return mode


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    mode = validate_args(args)

    if mode == "nfs-scan":
        output = discover_from_nfs(args)
    else:
        output = discover_from_longhorn_cr(args)

    print(json.dumps(output))


if __name__ == "__main__":
    main()
