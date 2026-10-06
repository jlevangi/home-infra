#!/usr/bin/env python3
"""Ad-hoc manifest assertions; no cluster mutations. Requires installed PyYAML."""
from pathlib import Path
import re
import subprocess
import yaml

repo = Path(__file__).resolve().parents[3]
render = subprocess.check_output(['kubectl', 'kustomize', str(repo / 'argocd/manifests/gitea/overlays/prod')], text=True)
objects = list(yaml.safe_load_all(render))
assert len(objects) == 6
by_kind = {o['kind']: o for o in objects}
assert len(by_kind) == 6
assert by_kind['Ingress']['metadata']['annotations']['external-dns.alpha.kubernetes.io/target'] == 'k3s-prod.levangie.dev'
for o in objects:
    assert o['metadata']['labels']['environment'] == 'prod'
    if o['kind'] != 'Namespace':
        assert o['metadata']['namespace'] == 'gitea'
pvc = by_kind['PersistentVolumeClaim']
assert pvc['spec']['storageClassName'] == 'longhorn-flash'
assert pvc['spec']['resources']['requests']['storage'] == '10Gi'
assert pvc['spec']['accessModes'] == ['ReadWriteOnce']
for group in ('daily', 'weekly'):
    assert pvc['metadata']['labels'][f'recurring-job-group.longhorn.io/{group}'] == 'enabled'
deploy = by_kind['Deployment']['spec']
assert deploy['replicas'] == 1 and deploy['strategy']['type'] == 'Recreate'
pod = deploy['template']['spec']
assert pod['automountServiceAccountToken'] is False
assert all(pod['securityContext'][k] == 1000 for k in ('runAsUser', 'runAsGroup', 'fsGroup'))
container, = pod['containers']
assert re.fullmatch(r'docker\.gitea\.com/gitea:28\.0\.0-rootless@sha256:[a-f0-9]{64}', container['image'])
assert container['volumeMounts'] == [{'name': 'data', 'mountPath': '/var/lib/gitea'}]
assert pod['volumes'][0]['persistentVolumeClaim']['claimName'] == pvc['metadata']['name']
assert container['readinessProbe']['httpGet']['path'] == '/api/healthz'
assert 'httpGet' not in container['livenessProbe']
assert container['resources'] == {'requests': {'cpu': '100m', 'memory': '256Mi'}, 'limits': {'cpu': '1000m', 'memory': '1Gi'}}
assert 'gitea generate secret SECRET_KEY' in container['args'][0]
config = by_kind['ConfigMap']['data']
assert config['GITEA_APP_INI'] == '/var/lib/gitea/config/app.ini'
assert config['GITEA__security__SECRET_KEY_URI'] == 'file:/var/lib/gitea/config/secret_key'
assert config['GITEA__database__PATH'].startswith('/var/lib/gitea/')
for section, key in [('security', 'INSTALL_LOCK'), ('security', 'DISABLE_WEBHOOKS'), ('service', 'DISABLE_REGISTRATION'), ('service', 'REQUIRE_SIGNIN_VIEW'), ('repository', 'FORCE_PRIVATE'), ('repository', 'DISABLE_MIGRATIONS'), ('server', 'DISABLE_SSH'), ('picture', 'DISABLE_GRAVATAR')]:
    assert config[f'GITEA__{section}__{key}'] == 'true'
for section in ('actions', 'mirror', 'mailer', 'cron.update_checker'):
    assert config[f'GITEA__{section}__ENABLED'] == 'false'
service = by_kind['Service']['spec']
assert service['type'] == 'ClusterIP'
assert len(service['ports']) == 1 and service['ports'][0]['port'] == 3000
assert service['selector'] == deploy['selector']['matchLabels']
app = yaml.safe_load((repo / 'argocd/apps/prod/gitea.yaml').read_text())
assert app['spec']['source']['repoURL'] == 'git@github.com:jlevangi/home-infra.git'
assert app['spec']['source']['path'] == 'argocd/manifests/gitea/overlays/prod'
assert not any(o['kind'] in ('Secret', 'Job', 'CronJob', 'StatefulSet') for o in objects)
print('PASS: 6 rendered resources; single replica/Recreate; persistent SQLite; backup labels; rootless digest; locked installer/signup; HTTPS ingress with internal auto DNS; GitHub source.')
