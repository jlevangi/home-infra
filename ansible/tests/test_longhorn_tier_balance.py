"""Exercise the actual Ansible selector pipeline, not a duplicated policy."""
import pathlib
import subprocess
import unittest
import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]


class TierBalance(unittest.TestCase):
    def test_selection(self):
        tasks = yaml.safe_load((ROOT / 'ansible/roles/cluster_platform/tasks/longhorn-post-config.yml').read_text())
        task = next(t for t in tasks if t['name'] == 'Check existing volumes with incorrect replica auto-balance setting')
        awk = task['shell'].split('    awk', 1)[-1] if '    awk' in task['shell'] else task['shell'].split('awk', 1)[1]
        command = 'awk' + awk.replace("{{ longhorn_replica_auto_balance | default('best-effort') }}", 'best-effort')
        data = '\n'.join(['tank:best-effort:["tank"]', 'flash:best-effort:["flash"]', 'empty:best-effort:[]', 'done:disabled:["tank"]', 'repair:disabled:["flash"]', 'mixed:best-effort:["tank","other"]']) + '\n'
        result = subprocess.run(['sh', '-c', command], input=data, text=True, capture_output=True, check=True)
        self.assertEqual(result.stdout.splitlines(), ['tank:disabled', 'repair:best-effort', 'mixed:disabled'])


if __name__ == '__main__':
    unittest.main()
