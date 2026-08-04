#!/usr/bin/env python3
import json
import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[2]
PLAYBOOK = ROOT / "ansible/playbooks/k3s-migrate-longhorn-pvc.yml"


class MigrationPlaybookTests(unittest.TestCase):
    def test_source_is_preflight_only_and_fail_closed(self):
        source = PLAYBOOK.read_text()
        required = (
            "migration_phase in ['preflight-stop', 'cutover', 'rollback']", "target_env == 'prod'",
            "capture-contract", "backup-volume", "argo-apps", "workloads",
            "Pause root Argo automated sync first", "Pause exact child Argo automated sync",
            "migration_state_file", "Destructive cutover is NOT AUTHORIZED",
            "No automatic resume was attempted", "migration_test_force_failure_after_stop",
            "deployment,statefulset,daemonset,job,cronjob,pod,replicaset",
            "ownershipProven", "verify-backup-url", "--backup-id {{ restore_backup_name | quote }}",
            "'cronJobs': migration_workloads.cronJobs", "{\"spec\":{\"suspend\":true}}",
            "Fetch first clean workload observation including ReplicaSets",
            "Fetch second clean workload observation including ReplicaSets",
            "Wait between clean workload observations", "ansible.builtin.pause: {seconds: 10}",
            "stopped.pods | length == 0", "stopped.cronJobs | map(attribute='name')",
        )
        for text in required:
            self.assertIn(text, source)
        forbidden = (
            "failed_when: false", "head -1", "finalizers", "delete pvc", "delete pv",
            "create volume", "resume Argo", "--all", "remove-finalizer",
        )
        lowered = source.lower()
        for text in forbidden:
            self.assertNotIn(text.lower(), lowered)
        preflight_rescue = source[source.index("rescue:"):source.index("# CUTOVER PLAY")]
        self.assertNotIn("patch application", preflight_rescue)
        self.assertNotIn("scale", preflight_rescue)
        self.assertIn("Re-pause root then child Argo after acceptance failure", source)
        self.assertIn("Re-suspend exact recorded CronJobs", source)
        self.assertIn("Scale exact recorded consumers back to zero", source)
        classifier = source.index("Report exact non-mutating cutover classification")
        destructive = source.index("&cutover_destructive")
        self.assertLess(classifier, destructive)
        self.assertIn("migration_classify_only | bool", source[classifier:destructive])
        self.assertIn("ansible.builtin.meta: end_play", source[classifier:destructive])

    def test_cutover_requires_origin_pool_and_stable_production_names(self):
        source = PLAYBOOK.read_text()
        required = (
            "migration_source_pool in ['flash', 'tank', 'unselected']",
            "migration_target_pool in ['flash', 'tank']",
            "migration_target_pool == migration_source_pool or migration_allow_pool_change | bool",
            "migration_target_storage_class == 'longhorn-one-replica-' ~ migration_target_pool",
            "migration_target_disk_selector == migration_target_pool",
            "not migration_target_pv.startswith('lh-')",
            "not migration_target_volume.startswith('lh-')",
            "'-migrated' not in migration_target_pv",
            "'-migrated' not in migration_target_volume",
        )
        for text in required:
            self.assertIn(text, source)
        self.assertIn("migration_target_pv: ''", source)
        self.assertIn("migration_target_volume: ''", source)

    def test_preflight_uses_operation_object_as_active_argo_gate(self):
        source = PLAYBOOK.read_text()
        self.assertIn("apps_by_name[restore_child_app].operation | default(None) == None", source)
        self.assertNotIn("status.operationState.phase | default('Succeeded') not in ['Running', 'Terminating']", source)

    @staticmethod
    def run_playbook(fake, log, *extra_vars):
        env = os.environ.copy()
        env["FAKE_KUBECTL_LOG"] = str(log)
        env["ANSIBLE_JINJA2_NATIVE"] = "true"
        return subprocess.run([
            "ansible-playbook", str(PLAYBOOK),
            "-e", "target_env=test", "-e", "restore_namespace=fixture",
            "-e", "restore_pvc_name=data", "-e", "restore_backup_name=backup-1",
            "-e", "restore_child_app=fixture", "-e", "restore_root_app=root-test",
            "-e", "migration_phase=preflight-stop", "-e", "migration_skip_confirmation=true",
            "-e", f"migration_kubectl={fake}", *sum((["-e", value] for value in extra_vars), []),
        ], cwd=ROOT, env=env, text=True, capture_output=True, check=False)

    def test_fake_kubectl_early_failure_exits_nonzero_without_mutation(self):
        if subprocess.run(["sh", "-c", "command -v ansible-playbook"], capture_output=True).returncode:
            self.skipTest("ansible-playbook unavailable")
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "kubectl.log"
            fake = Path(directory) / "kubectl"
            fake.write_text("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$FAKE_KUBECTL_LOG\"\nexit 42\n")
            fake.chmod(0o755)
            result = self.run_playbook(fake, log)
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            commands = log.read_text()
            self.assertIn("get pvc data", commands)
            self.assertNotIn(" patch ", f" {commands} ")
            self.assertNotIn(" scale ", f" {commands} ")

    def test_forced_failure_reaches_stopped_state_and_never_resumes(self):
        if subprocess.run(["sh", "-c", "command -v ansible-playbook"], capture_output=True).returncode:
            self.skipTest("ansible-playbook unavailable")
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "kubectl.log"
            fake = Path(directory) / "kubectl"
            fake.write_text(textwrap.dedent(r'''
                #!/usr/bin/env python3
                import json, os, sys
                argv = sys.argv[1:]
                with open(os.environ["FAKE_KUBECTL_LOG"], "a") as stream:
                    stream.write(json.dumps(argv) + "\n")
                pvc = {"apiVersion":"v1","kind":"PersistentVolumeClaim","metadata":{"name":"data","namespace":"fixture"},"spec":{"volumeName":"pv-data","accessModes":["ReadWriteOnce"],"resources":{"requests":{"storage":"1Gi"}}},"status":{"phase":"Bound"}}
                pv = {"apiVersion":"v1","kind":"PersistentVolume","metadata":{"name":"pv-data"},"spec":{"claimRef":{"namespace":"fixture","name":"data"},"csi":{"driver":"driver.longhorn.io","volumeHandle":"lh-1"},"capacity":{"storage":"1Gi"}}}
                volume = {"apiVersion":"longhorn.io/v1beta2","kind":"Volume","metadata":{"name":"lh-1","namespace":"longhorn-system"},"spec":{"size":1073741824},"status":{"state":"attached"}}
                backup = {"kind":"Backup","metadata":{"name":"backup-1","creationTimestamp":"2099-01-01T00:00:00Z"},"status":{"state":"Completed","volumeName":"lh-1","volumeSize":1073741824,"url":"s3://bucket/x?backup=backup-1&volume=lh-1","backupCreatedAt":"2099-01-01T00:00:00Z"}}
                root = {"metadata":{"name":"root-test"},"spec":{"destination":{"namespace":"argocd"},"syncPolicy":{"automated":{"prune":True}}},"status":{"operationState":{"phase":"Succeeded"}}}
                child = {"metadata":{"name":"fixture"},"spec":{"destination":{"namespace":"fixture"},"syncPolicy":{"automated":{"selfHeal":True}}},"status":{"operationState":{"phase":"Succeeded"}}}
                volumes = [{"name":"data","persistentVolumeClaim":{"claimName":"data"}}]
                deployment = {"kind":"Deployment","metadata":{"name":"web","namespace":"fixture","uid":"deploy-uid"},"spec":{"replicas":2,"template":{"spec":{"volumes":volumes}}}}
                rs = {"kind":"ReplicaSet","metadata":{"name":"web-rs","namespace":"fixture","uid":"rs-uid","ownerReferences":[{"kind":"Deployment","name":"web","uid":"deploy-uid","controller":True}]},"spec":{"template":{"spec":{}}}}
                pod = {"kind":"Pod","metadata":{"name":"web-pod","namespace":"fixture","ownerReferences":[{"kind":"ReplicaSet","name":"web-rs","uid":"rs-uid","controller":True}]},"spec":{"volumes":volumes}}
                cron = {"kind":"CronJob","metadata":{"name":"nightly","namespace":"fixture"},"spec":{"suspend":False,"jobTemplate":{"spec":{"template":{"spec":{"volumes":volumes}}}}}}
                if "patch" in argv or "scale" in argv:
                    print('{}')
                elif "jsonpath={.spec.syncPolicy.automated}" in argv:
                    print('', end='')
                elif "pvc" in argv: print(json.dumps(pvc))
                elif "pv" in argv: print(json.dumps(pv))
                elif "volumes.longhorn.io" in argv: print(json.dumps(volume))
                elif "backups.longhorn.io" in argv: print(json.dumps(backup))
                elif "backupvolumes.longhorn.io" in argv: print(json.dumps({"kind":"BackupVolumeList","items":[{"metadata":{"name":"bv-1"},"spec":{"volumeName":"lh-1"},"status":{"lastBackupName":"backup-1"}}]}))
                elif "applications.argoproj.io" in argv: print(json.dumps({"kind":"ApplicationList","items":[root,child]}))
                elif "deployment,statefulset,daemonset,job,cronjob,pod,replicaset" in argv: print(json.dumps({"kind":"List","items":[deployment,rs,pod,cron]}))
                else:
                    print("unsupported fake kubectl argv: " + repr(argv), file=sys.stderr)
                    sys.exit(64)
            ''').lstrip())
            fake.chmod(0o755)
            result = self.run_playbook(fake, log, "migration_test_force_failure_after_stop=true")
            output = result.stdout + result.stderr
            self.assertNotEqual(result.returncode, 0, output)
            self.assertIn("Forced failure after pause/scale for fail-closed test", output)
            self.assertIn("FAIL-CLOSED: Argo and workloads remain stopped", output)
            commands = [json.loads(line) for line in log.read_text().splitlines()]
            rendered = [" ".join(command) for command in commands]
            self.assertTrue(any("patch application root-test" in command and 'remove' in command for command in rendered), rendered)
            self.assertTrue(any("patch application fixture" in command and 'remove' in command for command in rendered), rendered)
            self.assertTrue(any("patch cronjob nightly" in command and 'suspend' in command and 'true' in command for command in rendered), rendered)
            self.assertTrue(any("scale deployment/web --replicas=0" in command for command in rendered), rendered)
            forbidden = ("--replicas=1", "--replicas=2", '"suspend":false', '"automated"', "--type=merge -p {\"spec\":{\"syncPolicy")
            after_scale = rendered[next(i for i, command in enumerate(rendered) if "--replicas=0" in command) + 1:]
            self.assertFalse(after_scale, after_scale)
            for text in forbidden:
                self.assertFalse(any(text in command for command in after_scale), rendered)


if __name__ == "__main__":
    unittest.main()
