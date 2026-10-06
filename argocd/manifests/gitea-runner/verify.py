#!/usr/bin/env python3
"""Render and assert the runner's privilege boundaries."""
import subprocess,yaml
from pathlib import Path
p=Path(__file__).parent
objs=list(yaml.safe_load_all(subprocess.check_output(['kubectl','kustomize',str(p/'overlays/prod')],text=True)))
b={o['kind']:o for o in objs}
assert len(objs)==10
assert b['Namespace']['metadata']['labels']['pod-security.kubernetes.io/enforce']=='restricted'
s=b['StatefulSet']['spec']['template']['spec']
assert s['securityContext']['runAsNonRoot']
assert not any('hostPath' in v for v in s['volumes'])
assert not s['containers'][0]['securityContext']['allowPrivilegeEscalation']
c=yaml.safe_load(b['ConfigMap']['data']['config.yaml'])
assert c['runner']['capacity']==1 and c['cache']['enabled'] is True
j=c['kubernetes']['pod_template']['spec']
assert j['automountServiceAccountToken'] is False
assert j['securityContext']['runAsNonRoot'] and j['securityContext']['runAsUser']==1001
assert c['container']['privileged'] is False
assert all(r['apiGroups']==[''] for r in b['Role']['rules'])
assert set(r for rule in b['Role']['rules'] for r in rule['resources'])=={'pods','pods/exec','pods/log','secrets'}
assert b['NetworkPolicy']['spec']['podSelector']=={}
assert b['ExternalSecret']['spec']['data'][0]['remoteRef']['key']=='prod/gitea-runner'
print('PASS: restricted namespace, namespace-only RBAC, bounded resources, no host mounts, nonroot job without API token, scoped ESO token, restricted egress')
