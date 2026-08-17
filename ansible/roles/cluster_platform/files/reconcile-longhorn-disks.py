#!/usr/bin/env python3
"""Reconcile a Longhorn node's disks and tags against the declared topology.

Driven by ansible/group_vars/k3s_cluster_topology.yml via
roles/cluster_platform/tasks/longhorn-node-disks.yml.

Behaviour is deliberately asymmetric:

  * Disks DECLARED in the topology are created if missing and corrected if
    their tags or scheduling flag drifted.
  * Disks present on the node but NOT declared are REPORTED, never removed.

The report-only half matters. Longhorn auto-creates a default disk at
`default-data-path` when a node registers, which is how k3s-prod-worker-4
ended up with its OS filesystem carrying 52 replicas in August 2026 with
nothing in git describing it. Surfacing that is useful; silently issuing
evictionRequested from a config file is not — a typo in a profile would
migrate every replica on a disk. Evictions stay a deliberate manual act.

Disks are matched by PATH, not by name. Longhorn disk names are arbitrary map
keys; the path is the real identity. Matching on name would make renaming a
disk in the topology look like "remove one disk, add another", i.e. a full
replica migration.
"""

import argparse
import json
import subprocess
import sys


def normalize_path(path):
    """Trailing slashes are not significant: /var/lib/longhorn/ == /var/lib/longhorn."""
    stripped = path.rstrip("/")
    return stripped if stripped else "/"


def kubectl(kubeconfig, *args, capture=True):
    cmd = ["kubectl", "--kubeconfig", kubeconfig, *args]
    result = subprocess.run(cmd, capture_output=capture, text=True)
    if result.returncode != 0:
        stderr = (result.stderr or "").strip()
        raise RuntimeError(f"{' '.join(cmd)} failed: {stderr}")
    return result.stdout


def fetch_node(kubeconfig, node):
    try:
        raw = kubectl(
            kubeconfig, "-n", "longhorn-system", "get", "nodes.longhorn.io", node, "-o", "json"
        )
    except RuntimeError:
        return None
    return json.loads(raw)


def build_desired_disks(live_disks, declared):
    """Return (desired_disks, changes) merging declared disks over the live spec.

    Only the fields this topology owns are written: path, tags, allowScheduling.
    Everything else on an existing disk (storageReserved, diskType, diskDriver)
    is preserved so this does not fight whatever else set them.
    """
    by_path = {normalize_path(d.get("path", "")): (name, d) for name, d in live_disks.items()}
    desired = dict(live_disks)
    changes = []

    for entry in declared:
        name = entry["name"]
        path = entry["path"]
        tags = entry.get("tags", [])
        allow = entry.get("allowScheduling", True)
        match = by_path.get(normalize_path(path))

        if match is None:
            desired[name] = {
                "path": path,
                "tags": tags,
                "allowScheduling": allow,
                "evictionRequested": False,
                "storageReserved": entry.get("storageReserved", 0),
                "diskType": entry.get("diskType", "filesystem"),
            }
            changes.append(f"register disk {name} at {path} tags={tags}")
            continue

        live_name, live = match
        merged = dict(live)
        if set(live.get("tags") or []) != set(tags):
            merged["tags"] = tags
            changes.append(
                f"retag disk {live_name} ({path}): {live.get('tags')} -> {tags}"
            )
        if bool(live.get("allowScheduling")) != bool(allow):
            merged["allowScheduling"] = allow
            changes.append(f"set allowScheduling={allow} on disk {live_name} ({path})")
        desired[live_name] = merged

    return desired, changes


def find_undeclared(live_disks, declared):
    declared_paths = {normalize_path(e["path"]) for e in declared}
    return [
        (name, disk.get("path"))
        for name, disk in sorted(live_disks.items())
        if normalize_path(disk.get("path", "")) not in declared_paths
    ]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--kubeconfig", required=True)
    parser.add_argument("--node", required=True)
    parser.add_argument("--disks", required=True, help="JSON list of declared disks")
    parser.add_argument("--node-tags", required=True, help="JSON list of node tags")
    parser.add_argument(
        "--check", action="store_true", help="report drift without patching anything"
    )
    args = parser.parse_args()

    declared = json.loads(args.disks)
    node_tags = json.loads(args.node_tags)

    node = fetch_node(args.kubeconfig, args.node)
    if node is None:
        # Not an error: the node may not have registered with Longhorn yet on a
        # first bootstrap. A later run reconciles it.
        print(f"INFO  {args.node}: not registered with Longhorn yet, skipping")
        return 0

    live_disks = node.get("spec", {}).get("disks") or {}
    live_tags = node.get("spec", {}).get("tags") or []

    desired_disks, changes = build_desired_disks(live_disks, declared)
    undeclared = find_undeclared(live_disks, declared)

    patch = {}
    if desired_disks != live_disks:
        patch["disks"] = desired_disks
    if set(live_tags) != set(node_tags):
        patch["tags"] = node_tags
        changes.append(f"node tags: {live_tags} -> {node_tags}")

    if patch and not args.check:
        kubectl(
            args.kubeconfig,
            "-n",
            "longhorn-system",
            "patch",
            "nodes.longhorn.io",
            args.node,
            "--type=merge",
            "-p",
            json.dumps({"spec": patch}),
            capture=True,
        )

    prefix = "WOULD " if args.check else ""
    for change in changes:
        print(f"CHANGE {args.node}: {prefix}{change}")
    if not changes:
        print(f"OK    {args.node}: disks and tags match topology")

    for name, path in undeclared:
        print(
            f"DRIFT {args.node}: disk '{name}' at {path} is registered in Longhorn "
            f"but not declared in the node topology (not removed — evict by hand "
            f"if unwanted)"
        )

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except RuntimeError as exc:
        print(f"ERROR {exc}", file=sys.stderr)
        sys.exit(1)
