#!/usr/bin/env python3
"""Fail-closed JSON contracts for Longhorn restore orchestration."""
import argparse
import copy
import datetime
import json
import sys
import urllib.parse


class ContractError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise ContractError(message)


def obj(value, name):
    require(isinstance(value, dict), f"{name} must be an object")
    return value


def array(value, name):
    require(isinstance(value, list), f"{name} must be an array")
    return value


def text(value, name):
    require(isinstance(value, str) and value != "", f"{name} must be a non-empty string")
    return value


def path(value, *keys):
    current = value
    for key in keys:
        current = obj(current, ".".join(keys))[key] if key in obj(current, ".".join(keys)) else None
    return current


def items(data, expected_kind=None):
    obj(data, "input")
    if expected_kind is not None:
        require(data.get("kind") == expected_kind, f"kind must be {expected_kind}")
    result = array(data.get("items"), "items")
    for index, item in enumerate(result):
        obj(item, f"items[{index}]")
    return result


def argo_apps(data, args):
    selected = {}
    targets = set(args.target_namespace)
    for item in items(data, "ApplicationList"):
        metadata = obj(item.get("metadata"), "application.metadata")
        spec = obj(item.get("spec"), "application.spec")
        name = text(metadata.get("name"), "application.metadata.name")
        destination = obj(spec.get("destination"), "application.spec.destination")
        sync = obj(spec.get("syncPolicy"), "application.spec.syncPolicy")
        automated_present = "automated" in sync
        if automated_present:
            obj(sync["automated"], "application.spec.syncPolicy.automated")
        relevant = name == args.root_app or destination.get("namespace") in targets
        if relevant and automated_present:
            require(name not in selected, f"duplicate application {name}")
            selected[name] = copy.deepcopy(item)
    require(args.root_app in selected, "root application with automated sync not found")
    children = sorted(name for name in selected if name != args.root_app)
    order = [args.root_app, *children]
    return {"applications": [selected[name] for name in order],
            "pauseOrder": order, "resumeOrder": [*children, args.root_app]}


def backup_volume(data, args):
    matches = []
    for item in items(data, "BackupVolumeList"):
        spec = obj(item.get("spec"), "backupVolume.spec")
        status = obj(item.get("status"), "backupVolume.status")
        if spec.get("volumeName") == args.source_volume and status.get("lastBackupName") == args.backup_id:
            matches.append(item)
    require(len(matches) == 1, f"expected exactly one matching BackupVolume, found {len(matches)}")
    return matches[0]


def resource(data, key, kind):
    value = obj(data.get(key), key)
    require(value.get("kind") == kind, f"{key}.kind must be {kind}")
    metadata = obj(value.get("metadata"), f"{key}.metadata")
    spec = obj(value.get("spec"), f"{key}.spec")
    return value, metadata, spec


def replay_contract(value):
    metadata = obj(value.get("metadata"), "resource.metadata")
    safe_metadata = {
        key: copy.deepcopy(metadata[key])
        for key in ("name", "namespace", "labels", "annotations")
        if key in metadata
    }
    return {
        "apiVersion": value.get("apiVersion"),
        "kind": value.get("kind"),
        "metadata": safe_metadata,
        "spec": copy.deepcopy(value["spec"]),
    }


def capture_contract(data, _args):
    obj(data, "input")
    _pvc, pvc_meta, pvc_spec = resource(data, "pvc", "PersistentVolumeClaim")
    _pv, pv_meta, pv_spec = resource(data, "pv", "PersistentVolume")
    _volume, volume_meta, volume_spec = resource(data, "volume", "Volume")
    namespace = text(pvc_meta.get("namespace"), "pvc.metadata.namespace")
    pvc_name = text(pvc_meta.get("name"), "pvc.metadata.name")
    pv_name = text(pv_meta.get("name"), "pv.metadata.name")
    volume_name = text(volume_meta.get("name"), "volume.metadata.name")
    require(volume_meta.get("namespace") == "longhorn-system", "volume must be in longhorn-system")
    require(pvc_spec.get("volumeName") == pv_name, "PVC volumeName does not match PV")
    claim = obj(pv_spec.get("claimRef"), "pv.spec.claimRef")
    require(claim.get("namespace") == namespace and claim.get("name") == pvc_name,
            "PV claimRef does not match PVC")
    csi = obj(pv_spec.get("csi"), "pv.spec.csi")
    require(csi.get("driver") == "driver.longhorn.io", "PV is not a Longhorn CSI volume")
    handle = text(csi.get("volumeHandle"), "pv.spec.csi.volumeHandle")
    require(handle == volume_name, "CSI volumeHandle does not match Longhorn Volume")
    return {
        "source": {"namespace": namespace, "pvcName": pvc_name, "pvName": pv_name,
                   "volumeHandle": handle, "longhornVolumeName": volume_name},
        "evidence": copy.deepcopy(data),
        "replaySafeContracts": {
            key: replay_contract(data[key]) for key in ("pvc", "pv", "volume")
        },
    }


def workload_volumes(item, kind):
    spec = obj(item.get("spec"), f"{kind}.spec")
    if kind in ("Deployment", "StatefulSet", "DaemonSet", "Job"):
        template = obj(spec.get("template"), f"{kind}.spec.template")
        pod_spec = obj(template.get("spec"), f"{kind}.spec.template.spec")
    elif kind == "CronJob":
        job_template = obj(spec.get("jobTemplate"), "CronJob.spec.jobTemplate")
        job_spec = obj(job_template.get("spec"), "CronJob.spec.jobTemplate.spec")
        template = obj(job_spec.get("template"), "CronJob.spec.jobTemplate.spec.template")
        pod_spec = obj(template.get("spec"), "CronJob.spec.jobTemplate.spec.template.spec")
    else:
        pod_spec = spec
    volumes = array(pod_spec.get("volumes"), f"{kind}.podSpec.volumes")
    for volume in volumes:
        obj(volume, f"{kind}.volume")
        if "persistentVolumeClaim" in volume:
            claim = obj(volume["persistentVolumeClaim"], f"{kind}.volume.persistentVolumeClaim")
            text(claim.get("claimName"), f"{kind}.volume.persistentVolumeClaim.claimName")
    return spec, volumes


def workloads(data, args):
    groups = {"scalableControllers": [], "daemonSets": [], "jobs": [], "cronJobs": [], "pods": []}
    identities = set()
    for item in items(data, "List"):
        kind = item.get("kind")
        require(kind in ("Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob", "Pod"),
                f"unsupported workload kind {kind!r}")
        metadata = obj(item.get("metadata"), f"{kind}.metadata")
        name = text(metadata.get("name"), f"{kind}.metadata.name")
        namespace = text(metadata.get("namespace"), f"{kind}.metadata.namespace")
        identity = (kind, namespace, name)
        require(identity not in identities, f"duplicate workload {kind}/{namespace}/{name}")
        identities.add(identity)
        spec, volumes = workload_volumes(item, kind)
        if namespace != args.namespace:
            continue
        matched = any(volume.get("persistentVolumeClaim", {}).get("claimName") == args.pvc
                      for volume in volumes)
        if not matched:
            continue
        record = {"kind": kind, "name": name, "namespace": namespace}
        if kind == "Pod":
            groups["pods"].append(record)
        elif kind in ("Deployment", "StatefulSet"):
            replicas = spec.get("replicas", 1)
            require(isinstance(replicas, int) and not isinstance(replicas, bool) and replicas >= 0,
                    f"{kind}.spec.replicas must be a non-negative integer")
            record["replicas"] = replicas
            groups["scalableControllers"].append(record)
        elif kind == "DaemonSet":
            groups["daemonSets"].append(record)
        elif kind == "Job":
            groups["jobs"].append(record)
        else:
            groups["cronJobs"].append(record)
    key = lambda value: (value["kind"], value["name"])
    return {name: sorted(records, key=key) for name, records in groups.items()}


def timestamp(value, name):
    text(value, name)
    try:
        parsed = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise ContractError(f"{name} must be an ISO-8601 timestamp") from error
    require(parsed.tzinfo is not None, f"{name} must include a timezone")
    return parsed


def verify_backup(data, args):
    obj(data, "input")
    require(data.get("kind") == "Backup", "kind must be Backup")
    metadata = obj(data.get("metadata"), "backup.metadata")
    status = obj(data.get("status"), "backup.status")
    require(metadata.get("name") == args.backup_id, "backup metadata.name identity mismatch")
    require(status.get("volumeName") == args.restored_volume, "backup volume identity mismatch")
    require(status.get("state") == "Completed", "backup is not Completed")
    url = text(status.get("url"), "backup.status.url")
    try:
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(url).query, strict_parsing=True)
    except ValueError as error:
        raise ContractError("backup.status.url must have a valid query") from error
    require(query.get("backup") == [args.backup_id], "backup URL backup parameter mismatch")
    require(query.get("volume") == [args.restored_volume], "backup URL volume parameter mismatch")
    cutover = timestamp(args.cutover, "cutover")
    require(timestamp(metadata.get("creationTimestamp"), "backup.metadata.creationTimestamp") > cutover,
            "backup creationTimestamp is not after cutover")
    require(timestamp(status.get("backupCreatedAt"), "backup.status.backupCreatedAt") > cutover,
            "backup backupCreatedAt is not after cutover")
    return data


def parser():
    result = argparse.ArgumentParser()
    commands = result.add_subparsers(dest="command", required=True)
    argo = commands.add_parser("argo-apps")
    argo.add_argument("--root-app", required=True)
    argo.add_argument("--target-namespace", action="append", required=True)
    argo.set_defaults(handler=argo_apps)
    backup = commands.add_parser("backup-volume")
    backup.add_argument("--source-volume", required=True)
    backup.add_argument("--backup-id", required=True)
    backup.set_defaults(handler=backup_volume)
    capture = commands.add_parser("capture-contract")
    capture.set_defaults(handler=capture_contract)
    work = commands.add_parser("workloads")
    work.add_argument("--namespace", required=True)
    work.add_argument("--pvc", required=True)
    work.set_defaults(handler=workloads)
    verify = commands.add_parser("verify-backup")
    verify.add_argument("--backup-id", required=True)
    verify.add_argument("--restored-volume", required=True)
    verify.add_argument("--cutover", required=True)
    verify.set_defaults(handler=verify_backup)
    return result


def main():
    try:
        args = parser().parse_args()
        data = json.load(sys.stdin)
        output = args.handler(data, args)
        json.dump(output, sys.stdout, sort_keys=True, separators=(",", ":"))
        sys.stdout.write("\n")
    except (ContractError, KeyError, TypeError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
