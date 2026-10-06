#!/usr/bin/env python3
"""Run only against the isolated trial; credentials stay in process memory."""
import base64
import http.cookiejar
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request

K = ['kubectl', '--kubeconfig', '/home/pierce/.kube/gitea-recovery.yaml', '-n', 'gitea-recovery']
BASE = 'http://127.0.0.1:13000'

def run(args, **kw):
    return subprocess.check_output(args, stderr=subprocess.PIPE, **kw).decode()

assert run(K + ['config', 'view', '--minify', '-o', 'jsonpath={.clusters[0].cluster.server}']) == 'https://172.20.21.124:6443'
baseline = json.loads(Path('/tmp/gitea-recovery-baseline.json').read_text())
# Controller-only, read-only access: never send Vault credentials to the trial.
token = base64.b64decode(run(['kubectl', '--kubeconfig', '/home/pierce/.kube/config', '--context', 'k3s-prod', '-n', 'vault-raft', 'get', 'secret', 'vault-init', '-o', 'jsonpath={.data.root-token}'])).decode()
req = urllib.request.Request('https://vault.levangie.dev/v1/kv/data/prod/hermes-vaultwarden', headers={'X-Vault-Token': token})
with urllib.request.urlopen(req, timeout=20) as response:
    master = json.load(response)['data']['data']['VW_MASTER_PASSWORD']
del token, req
env = os.environ | {'VW_MASTER_PASSWORD': master}
user = run(['/home/pierce/.local/bin/vw-get', 'get', 'Gitea - Hermes', 'username'], env=env).strip()
password = run(['/home/pierce/.local/bin/vw-get', 'get', 'Gitea - Hermes', 'password'], env=env).strip()
del master, env

def validate():
    pf = subprocess.Popen(K + ['port-forward', '--address=127.0.0.1', 'deploy/gitea', '13000:3000'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(40):
            try:
                with urllib.request.urlopen(BASE + '/api/healthz', timeout=2) as r:
                    assert json.load(r)['status'] == 'pass'
                break
            except OSError:
                time.sleep(0.5)
        else:
            raise RuntimeError('health timeout')
        cookie = http.cookiejar.CookieJar()
        opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cookie))
        page = opener.open(BASE + '/user/login').read().decode()
        csrf = re.search(r'<input[^>]*name="_csrf"[^>]*>', page)
        csrf = re.search(r'value="([^"]+)"', csrf[0]) if csrf else None
        # v28 login has no hidden CSRF field; preserve one if present.
        fields = {'user_name': user, 'password': password}
        if csrf:
            fields['_csrf'] = csrf[1]
        data = urllib.parse.urlencode(fields).encode()
        response = opener.open(urllib.request.Request(BASE + '/user/login', data=data))
        assert '/user/login' not in response.url, 'local web login failed'
        auth = base64.b64encode((user + ':' + password).encode()).decode()
        def api(path):
            req = urllib.request.Request(BASE + '/api/v1/' + path, headers={'Authorization': 'Basic ' + auth})
            with urllib.request.urlopen(req, timeout=20) as r:
                return json.load(r)
        assert api('user')['login'].lower() == user.lower()
        repo = 'repos/' + baseline['repository']
        assert {x['name']: x['commit']['id'] for x in api(repo + '/branches')} == baseline['branches']
        assert {x['name']: x['commit']['sha'] for x in api(repo + '/tags')} == baseline['tags']
        assert api(repo + '/contents/recovery-check.txt?ref=main')['sha'] == baseline['file_sha']
        assert [x['title'] for x in api(repo + '/issues?state=all')] == baseline['issue_titles']
        with tempfile.TemporaryDirectory(prefix='gitea-trial-client-') as tmp:
            askpass = Path(tmp) / 'askpass'
            askpass.write_text('#!/usr/bin/env python3\nimport os,sys\nprint(os.environ["TRIAL_USER"] if "Username" in sys.argv[1] else os.environ["TRIAL_PASSWORD"])\n')
            askpass.chmod(0o700)
            e = os.environ | {'GIT_ASKPASS': str(askpass), 'GIT_TERMINAL_PROMPT': '0', 'TRIAL_USER': user, 'TRIAL_PASSWORD': password}
            run(['git', '-c', 'credential.helper=', 'clone', '--mirror', BASE + '/' + baseline['repository'] + '.git', tmp + '/clone.git'], env=e)
            refs = dict(line.split()[::-1] for line in run(['git', '--git-dir=' + tmp + '/clone.git', 'show-ref']).splitlines())
            expected = {'refs/heads/' + k: v for k,v in baseline['branches'].items()} | {'refs/tags/' + k:v for k,v in baseline['tags'].items()}
            assert refs == expected
            assert run(['git', '--git-dir=' + tmp + '/clone.git', 'rev-parse', 'main:recovery-check.txt']).strip() == baseline['file_sha']
            run(['git', '--git-dir=' + tmp + '/clone.git', 'fsck', '--full'])
        return {'health': 'pass', 'local_web_login': 'pass', 'authenticated_api': 'pass', 'branches_tags': 'pass', 'file_blob': 'pass', 'issue_title': 'pass', 'authenticated_mirror_clone_fsck': 'pass'}
    finally:
        pf.terminate()
        pf.wait(timeout=10)

try:
    before = validate()
    old = json.loads(run(K + ['get', 'pods', '-l', 'app=gitea-trial', '-o', 'json']))['items'][0]
    run(K + ['delete', 'pod', old['metadata']['name']])
    run(K + ['rollout', 'status', 'deploy/gitea', '--timeout=120s'])
    after = validate()
    new = json.loads(run(K + ['get', 'pods', '-l', 'app=gitea-trial', '-o', 'json']))['items'][0]
    assert old['metadata']['uid'] != new['metadata']['uid']
    result = {'before': before, 'after': after, 'old_pod_uid': old['metadata']['uid'], 'new_pod_uid': new['metadata']['uid'], 'pod_replacement_persistence': 'pass', 'attachment': 'not tested: no fixture', 'issue_body_id': 'not compared: baseline contains title only'}
    Path('/tmp/gitea-recovery-results.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
except Exception as exc:
    import traceback
    print('VALIDATION FAILED:', type(exc).__name__, str(exc) if isinstance(exc, AssertionError) else '')
    print('Failure line:', traceback.extract_tb(exc.__traceback__)[-1].lineno)
    raise SystemExit(1)
