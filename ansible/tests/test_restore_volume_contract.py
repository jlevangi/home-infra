#!/usr/bin/env python3
import json
import subprocess
import sys
import unittest
from pathlib import Path

SCRIPT = Path(__file__).parents[1] / "roles/k3s/files/restore-volume-contract.py"


def run(*args, data):
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args], input=json.dumps(data), text=True,
        capture_output=True, check=False,
    )


class ContractTests(unittest.TestCase):
    def ok(self, *args, data):
        result = run(*args, data=data)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def bad(self, *args, data):
        result = run(*args, data=data)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(result.stdout.strip())

    def test_argo_apps_exact_capture_and_order(self):
        root = {"metadata": {"name": "root"}, "spec": {"syncPolicy": {"automated": {}, "retry": {"limit": 2}}, "destination": {"namespace": "argocd"}}}
        zed = {"metadata": {"name": "zed", "labels": {"x": "y"}}, "spec": {"syncPolicy": {"automated": {"prune": False}}, "destination": {"namespace": "target"}}}
        alpha = {"metadata": {"name": "alpha"}, "spec": {"syncPolicy": {"automated": {"selfHeal": True}}, "destination": {"namespace": "target"}}}
        manual = {"metadata": {"name": "manual"}, "spec": {"syncPolicy": {}, "destination": {"namespace": "target"}}}
        out = self.ok("argo-apps", "--root-app", "root", "--target-namespace", "target", data={"kind": "ApplicationList", "items": [zed, manual, root, alpha]})
        self.assertEqual(out["applications"], [root, alpha, zed])
        self.assertEqual(out["pauseOrder"], ["root", "alpha", "zed"])
        self.assertEqual(out["resumeOrder"], ["alpha", "zed", "root"])
        self.assertEqual(out["applications"][0]["spec"]["syncPolicy"]["automated"], {})

    def test_argo_fails_closed(self):
        self.bad("argo-apps", "--root-app", "root", "--target-namespace", "x", data={"items": {}})
        self.bad("argo-apps", "--root-app", "root", "--target-namespace", "x", data={"kind": "ApplicationList", "items": [{"metadata": {"name": "root"}, "spec": {"syncPolicy": {"automated": None}}}]})
        duplicate = {"metadata": {"name": "root"}, "spec": {"syncPolicy": {"automated": {}}, "destination": {"namespace": "x"}}}
        self.bad("argo-apps", "--root-app", "root", "--target-namespace", "x", data={"kind": "ApplicationList", "items": [duplicate, duplicate]})

    def test_backup_volume_requires_unique_exact_match(self):
        match = {"metadata": {"name": "bv-good"}, "spec": {"volumeName": "vol-a"}, "status": {"lastBackupName": "backup-1"}}
        wrong = {"metadata": {"name": "bv-old"}, "spec": {"volumeName": "vol-a"}, "status": {"lastBackupName": "backup-0"}}
        self.assertEqual(self.ok("backup-volume", "--source-volume", "vol-a", "--backup-id", "backup-1", data={"kind": "BackupVolumeList", "items": [wrong, match]}), match)
        self.bad("backup-volume", "--source-volume", "vol-a", "--backup-id", "missing", data={"items": [match]})
        self.bad("backup-volume", "--source-volume", "vol-a", "--backup-id", "backup-1", data={"items": [match, match]})
        self.bad("backup-volume", "--source-volume", "vol-a", "--backup-id", "backup-1", data={"kind": "List", "items": [match]})

    def fixture(self):
        pvc = {"apiVersion": "v1", "kind": "PersistentVolumeClaim", "metadata": {"name": "data", "namespace": "app", "labels": {"keep": "all"}, "finalizers": ["protect"]}, "spec": {"volumeName": "pv-data", "accessModes": ["ReadWriteOnce"], "resources": {"requests": {"storage": "1Gi"}}}, "status": {"phase": "Bound"}}
        pv = {"apiVersion": "v1", "kind": "PersistentVolume", "metadata": {"name": "pv-data", "annotations": {"a": "b"}}, "spec": {"claimRef": {"namespace": "app", "name": "data"}, "csi": {"driver": "driver.longhorn.io", "volumeHandle": "lh-1"}, "capacity": {"storage": "1Gi"}}}
        volume = {"apiVersion": "longhorn.io/v1beta2", "kind": "Volume", "metadata": {"name": "lh-1", "namespace": "longhorn-system", "labels": {"backup": "yes"}}, "spec": {"size": "1073741824", "numberOfReplicas": 2}, "status": {"state": "detached"}}
        return {"pvc": pvc, "pv": pv, "volume": volume}

    def test_capture_contract_separates_evidence_from_replay_safe_contracts(self):
        data = self.fixture()
        data["pvc"]["metadata"].update({"uid": "u", "resourceVersion": "7", "generation": 2,
            "managedFields": [{}], "creationTimestamp": "now", "deletionTimestamp": "later",
            "deletionGracePeriodSeconds": 30, "ownerReferences": [{"name": "owner"}]})
        out = self.ok("capture-contract", data=data)
        self.assertEqual(out["source"], {"namespace": "app", "pvcName": "data", "pvName": "pv-data", "volumeHandle": "lh-1", "longhornVolumeName": "lh-1"})
        self.assertEqual(out["evidence"], data)
        replay = out["replaySafeContracts"]["pvc"]
        self.assertEqual(replay["metadata"], {"name": "data", "namespace": "app", "labels": {"keep": "all"}})
        self.assertNotIn("status", replay)
        self.assertEqual(replay["spec"], data["pvc"]["spec"])

    def test_capture_contract_rejects_incoherent_or_malformed_objects(self):
        for mutation in ("pvc-volume", "claim-name", "claim-namespace", "handle", "driver", "kind"):
            data = self.fixture()
            if mutation == "pvc-volume": data["pvc"]["spec"]["volumeName"] = "other"
            if mutation == "claim-name": data["pv"]["spec"]["claimRef"]["name"] = "other"
            if mutation == "claim-namespace": data["pv"]["spec"]["claimRef"]["namespace"] = "other"
            if mutation == "handle": data["pv"]["spec"]["csi"]["volumeHandle"] = "other"
            if mutation == "driver": data["pv"]["spec"]["csi"]["driver"] = "other.csi"
            if mutation == "kind": data["volume"]["kind"] = "NotVolume"
            self.bad("capture-contract", data=data)

    def test_workloads_exact_references_and_zero_replicas(self):
        deployment = {"kind": "Deployment", "metadata": {"name": "web", "namespace": "app"}, "spec": {"replicas": 0, "template": {"spec": {"volumes": [{"name": "d", "persistentVolumeClaim": {"claimName": "data"}}]}}}}
        sts = {"kind": "StatefulSet", "metadata": {"name": "db", "namespace": "app"}, "spec": {"template": {"spec": {"volumes": [{"persistentVolumeClaim": {"claimName": "database"}}]}}}}
        pod = {"kind": "Pod", "metadata": {"name": "raw", "namespace": "app"}, "spec": {"volumes": [{"persistentVolumeClaim": {"claimName": "data"}}]}}
        out = self.ok("workloads", "--namespace", "app", "--pvc", "data", data={"kind": "List", "items": [sts, pod, deployment]})
        self.assertEqual(out, {"scalableControllers": [{"kind": "Deployment", "name": "web", "namespace": "app", "replicas": 0}], "daemonSets": [], "jobs": [], "cronJobs": [], "pods": [{"kind": "Pod", "name": "raw", "namespace": "app"}]})

    def test_workloads_covers_all_pod_template_consumers(self):
        volume = {"volumes": [{"persistentVolumeClaim": {"claimName": "data"}}]}
        def controller(kind, name):
            spec = {"template": {"spec": volume}}
            if kind == "CronJob": spec = {"jobTemplate": {"spec": spec}}
            return {"kind": kind, "metadata": {"name": name, "namespace": "app"}, "spec": spec}
        data = {"kind": "List", "items": [controller("DaemonSet", "ds"), controller("Job", "job"), controller("CronJob", "cron")]}
        out = self.ok("workloads", "--namespace", "app", "--pvc", "data", data=data)
        self.assertEqual([out[key][0]["kind"] for key in ("daemonSets", "jobs", "cronJobs")], ["DaemonSet", "Job", "CronJob"])

    def test_workloads_rejects_wrong_list_kind_and_duplicate_identity(self):
        item = {"kind": "Pod", "metadata": {"name": "p", "namespace": "app"}, "spec": {"volumes": []}}
        self.bad("workloads", "--namespace", "app", "--pvc", "data", data={"kind": "PodList", "items": [item]})
        self.bad("workloads", "--namespace", "app", "--pvc", "data", data={"kind": "List", "items": [item, item]})

    def test_workloads_fails_closed_on_malformed_input(self):
        self.bad("workloads", "--namespace", "app", "--pvc", "data", data={"items": [{"kind": "Deployment", "metadata": {"name": "x", "namespace": "app"}, "spec": {}}]})
        self.bad("workloads", "--namespace", "app", "--pvc", "data", data={"kind": "List", "items": [{"kind": "DaemonSet", "metadata": {"name": "x", "namespace": "app"}, "spec": {"volumes": []}}]})

    def test_destructive_restore_is_blocked_before_mutation(self):
        playbook = (Path(__file__).parents[1] / "playbooks/k3s-restore-from-backup.yml").read_text()
        gate = playbook.index("Block unsafe restore workflow pending fail-closed hardening")
        mutation = playbook.index("Restore each volume with ArgoCD sync paused")
        self.assertLess(gate, mutation)
        self.assertIn("restore_action == 'list'", playbook[gate:mutation])

    def test_verify_backup_requires_identity_state_url_and_fresh_timestamp(self):
        backup = {"apiVersion": "longhorn.io/v1beta2", "kind": "Backup", "metadata": {"name": "backup-new", "creationTimestamp": "2026-08-03T12:01:00Z"}, "spec": {"backupMode": "incremental"}, "status": {"state": "Completed", "volumeName": "restored", "url": "s3://bucket/path?backup=backup-new&volume=restored", "backupCreatedAt": "2026-08-03T12:02:00Z"}}
        argv = ("verify-backup", "--backup-id", "backup-new", "--restored-volume", "restored", "--cutover", "2026-08-03T12:00:00Z")
        self.assertEqual(self.ok(*argv, data=backup), backup)
        cases = [
            ("status", "volumeName", "other"), ("status", "state", "Error"),
            ("status", "url", ""), ("status", "backupCreatedAt", "2026-08-03T11:59:00Z"),
            ("metadata", "creationTimestamp", "2026-08-03T11:59:00Z"),
        ]
        for section, key, value in cases:
            bad = json.loads(json.dumps(backup)); bad[section][key] = value
            self.bad(*argv, data=bad)
        bad = json.loads(json.dumps(backup)); bad["status"].pop("backupCreatedAt")
        self.bad(*argv, data=bad)
        for mutation in ("name", "backup-query", "volume-query", "duplicate-query"):
            bad = json.loads(json.dumps(backup))
            if mutation == "name": bad["metadata"]["name"] = "other"
            if mutation == "backup-query": bad["status"]["url"] = "s3://b?backup=other&volume=restored"
            if mutation == "volume-query": bad["status"]["url"] = "s3://b?backup=backup-new&volume=other"
            if mutation == "duplicate-query": bad["status"]["url"] += "&backup=backup-new"
            self.bad(*argv, data=bad)


if __name__ == "__main__":
    unittest.main()
