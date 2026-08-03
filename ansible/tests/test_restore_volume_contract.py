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
        self.assertFalse(out["pods"][0]["ownershipProven"])
        self.assertEqual(out["scalableControllers"][0]["replicas"], 0)

    def test_workloads_covers_all_pod_template_consumers(self):
        volume = {"volumes": [{"persistentVolumeClaim": {"claimName": "data"}}]}
        def controller(kind, name):
            spec = {"template": {"spec": volume}}
            if kind == "CronJob": spec = {"jobTemplate": {"spec": spec}}
            return {"kind": kind, "metadata": {"name": name, "namespace": "app"}, "spec": spec}
        data = {"kind": "List", "items": [controller("DaemonSet", "ds"), controller("Job", "job"), controller("CronJob", "cron")]}
        out = self.ok("workloads", "--namespace", "app", "--pvc", "data", data=data)
        self.assertEqual([out[key][0]["kind"] for key in ("daemonSets", "jobs", "cronJobs")], ["DaemonSet", "Job", "CronJob"])

    def test_workloads_omitted_volumes_cron_suspend_and_proven_pod_ownership(self):
        volume = {"volumes": [{"persistentVolumeClaim": {"claimName": "data"}}]}
        deployment = {"kind": "Deployment", "metadata": {"name": "web", "namespace": "app", "uid": "deploy-uid"}, "spec": {"template": {"spec": {}}}}
        rs = {"kind": "ReplicaSet", "metadata": {"name": "web-rs", "namespace": "app", "uid": "rs-uid", "ownerReferences": [{"kind": "Deployment", "name": "web", "uid": "deploy-uid", "controller": True}]}, "spec": {"template": {"spec": {}}}}
        pod = {"kind": "Pod", "metadata": {"name": "web-pod", "namespace": "app", "ownerReferences": [{"kind": "ReplicaSet", "name": "web-rs", "uid": "rs-uid", "controller": True}]}, "spec": volume}
        cron = lambda name, suspend: {"kind": "CronJob", "metadata": {"name": name, "namespace": "app"}, "spec": {**({} if suspend is None else {"suspend": suspend}), "jobTemplate": {"spec": {"template": {"spec": volume}}}}}
        out = self.ok("workloads", "--namespace", "app", "--pvc", "data", data={"kind": "List", "items": [deployment, rs, pod, cron("absent", None), cron("false", False), cron("true", True)]})
        self.assertTrue(out["pods"][0]["ownershipProven"])
        self.assertEqual(out["pods"][0]["ownerChain"], ["ReplicaSet/web-rs", "Deployment/web"])
        self.assertEqual(out["cronJobs"], [{"kind": "CronJob", "name": "absent", "namespace": "app", "suspendPresent": False}, {"kind": "CronJob", "name": "false", "namespace": "app", "suspend": False, "suspendPresent": True}, {"kind": "CronJob", "name": "true", "namespace": "app", "suspend": True, "suspendPresent": True}])

    def test_workloads_owner_uid_missing_or_mismatch_is_unproven(self):
        volume = {"volumes": [{"persistentVolumeClaim": {"claimName": "data"}}]}
        for missing, pod_uid, deployment_uid in (("pod", None, "deploy-uid"), ("rs", "rs-uid", "deploy-uid"),
                                                  ("deployment", "rs-uid", None), (None, "wrong-rs", "deploy-uid"),
                                                  (None, "rs-uid", "wrong-deploy")):
            deployment = {"kind": "Deployment", "metadata": {"name": "web", "namespace": "app", **({} if missing == "deployment" else {"uid": "deploy-uid"})}, "spec": {"template": {"spec": {}}}}
            rs = {"kind": "ReplicaSet", "metadata": {"name": "web-rs", "namespace": "app", **({} if missing == "rs" else {"uid": "rs-uid"}), "ownerReferences": [{"kind": "Deployment", "name": "web", **({} if deployment_uid is None else {"uid": deployment_uid}), "controller": True}]}, "spec": {"template": {"spec": {}}}}
            pod = {"kind": "Pod", "metadata": {"name": "web-pod", "namespace": "app", "ownerReferences": [{"kind": "ReplicaSet", "name": "web-rs", **({} if pod_uid is None else {"uid": pod_uid}), "controller": True}]}, "spec": volume}
            out = self.ok("workloads", "--namespace", "app", "--pvc", "data", data={"kind": "List", "items": [deployment, rs, pod]})
            self.assertFalse(out["pods"][0]["ownershipProven"], missing)

    def test_workloads_direct_owner_requires_matching_uid(self):
        volume = {"volumes": [{"persistentVolumeClaim": {"claimName": "data"}}]}
        for controller_uid, owner_uid, expected in (("job-uid", "job-uid", True), (None, "job-uid", False),
                                                    ("job-uid", None, False), ("job-uid", "wrong", False)):
            job = {"kind": "Job", "metadata": {"name": "worker", "namespace": "app", **({} if controller_uid is None else {"uid": controller_uid})}, "spec": {"template": {"spec": {}}}}
            pod = {"kind": "Pod", "metadata": {"name": "worker-pod", "namespace": "app", "ownerReferences": [{"kind": "Job", "name": "worker", **({} if owner_uid is None else {"uid": owner_uid}), "controller": True}]}, "spec": volume}
            out = self.ok("workloads", "--namespace", "app", "--pvc", "data", data={"kind": "List", "items": [job, pod]})
            self.assertEqual(out["pods"][0]["ownershipProven"], expected)

    def test_workloads_rejects_unproven_and_malformed_ownership(self):
        volume = {"volumes": [{"persistentVolumeClaim": {"claimName": "data"}}]}
        for owners in ([], [{"kind": "Custom", "name": "x", "controller": True}], [{"kind": "ReplicaSet", "name": "missing", "controller": True}], [{"kind": "Job", "name": "a", "controller": True}, {"kind": "Job", "name": "b", "controller": True}]):
            pod = {"kind": "Pod", "metadata": {"name": "p", "namespace": "app", "ownerReferences": owners}, "spec": volume}
            out = self.ok("workloads", "--namespace", "app", "--pvc", "data", data={"kind": "List", "items": [pod]})
            self.assertFalse(out["pods"][0]["ownershipProven"])
        malformed = {"kind": "Pod", "metadata": {"name": "p", "namespace": "app"}, "spec": {"volumes": {}}}
        self.bad("workloads", "--namespace", "app", "--pvc", "data", data={"kind": "List", "items": [malformed]})

    def test_verify_backup_url_exact_params_without_timestamp(self):
        argv = ("verify-backup-url", "--backup-id", "b1", "--volume", "v1")
        self.assertEqual(self.ok(*argv, data={"url": "s3://bucket/x?backup=b1&volume=v1"}), {"url": "s3://bucket/x?backup=b1&volume=v1"})
        for url in ("s3://x?backup=bad&volume=v1", "s3://x?backup=b1&volume=bad", "s3://x?backup=b1&backup=b1&volume=v1"):
            self.bad(*argv, data={"url": url})

    def test_engine_requires_one_exact_volume_match(self):
        good = {"metadata": {"name": "engine-a"}, "spec": {"volumeName": "target"}}
        other = {"metadata": {"name": "engine-b"}, "spec": {"volumeName": "other"}}
        self.assertEqual(self.ok("engine", "--volume", "target", data={"kind": "EngineList", "items": [other, good]}), good)
        self.bad("engine", "--volume", "target", data={"kind": "EngineList", "items": []})
        self.bad("engine", "--volume", "target", data={"kind": "EngineList", "items": [good, good]})

    def test_migration_resources_replays_distinct_retain_target(self):
        contract = self.ok("capture-contract", data=self.fixture())
        state = {"storageContract": contract,
                 "selectedBackup": {"metadata": {"name": "backup-1"}, "status": {"state": "Completed", "volumeName": "lh-1", "url": "nfs://nas/x?backup=backup-1&volume=lh-1"}},
                 "backupVolume": {"metadata": {"name": "bv-1"}}}
        argv = ("migration-resources", "--target-pv", "pv-target", "--target-volume", "lh-target",
                "--target-storage-class", "longhorn-one-replica-tank", "--target-disk-selector", "tank",
                "--target-replicas", "1")
        out = self.ok(*argv, data={"state": state})
        self.assertEqual(out["pvc"]["spec"]["volumeName"], "pv-target")
        self.assertEqual(out["pv"]["spec"]["persistentVolumeReclaimPolicy"], "Retain")
        self.assertEqual(out["pv"]["spec"]["csi"]["volumeHandle"], "lh-target")
        self.assertNotIn("claimRef", out["pv"]["spec"])
        self.assertEqual(out["volume"]["spec"]["numberOfReplicas"], 1)
        self.assertEqual(out["volume"]["spec"]["diskSelector"], ["tank"])
        self.assertEqual(out["volume"]["metadata"]["labels"]["backup-volume"], "bv-1")
        for bad_target in (("pv-data", "lh-target"), ("pv-target", "lh-1")):
            self.bad("migration-resources", "--target-pv", bad_target[0], "--target-volume", bad_target[1],
                     "--target-storage-class", "longhorn-one-replica-tank", "--target-disk-selector", "tank",
                     "--target-replicas", "1", data={"state": state})

    def test_verify_target_binding_requires_exact_retain_contract(self):
        data = self.fixture()
        data["pvc"]["spec"]["volumeName"] = "pv-target"
        data["pv"]["metadata"]["name"] = "pv-target"
        data["pv"]["spec"]["claimRef"] = {"namespace": "app", "name": "data"}
        data["pv"]["spec"]["persistentVolumeReclaimPolicy"] = "Retain"
        data["pv"]["spec"]["csi"]["volumeHandle"] = "lh-target"
        data["volume"]["metadata"]["name"] = "lh-target"
        data["volume"]["metadata"]["labels"]["backup-volume"] = "bv-1"
        data["volume"]["spec"]["numberOfReplicas"] = 1
        data["volume"]["spec"]["diskSelector"] = ["tank"]
        argv = ("verify-target-binding", "--namespace", "app", "--pvc", "data", "--pv", "pv-target",
                "--volume", "lh-target", "--replicas", "1", "--disk-selector", "tank", "--backup-volume", "bv-1")
        self.assertEqual(self.ok(*argv, data=data), data)
        data["pv"]["spec"]["persistentVolumeReclaimPolicy"] = "Delete"
        self.bad(*argv, data=data)

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
