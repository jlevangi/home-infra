#!/usr/bin/env python3
"""Regenerate the Glance ConfigMap from standalone YAML files.

Usage:
    python3 sync-configmap.py

Reads glance.yml and server.yml, merges them into a single config,
and writes configmap.yaml with proper block scalars.

The standalone files are the source of truth for human editing.
The ConfigMap is the derived artifact for Kubernetes.
"""
import yaml
import sys
from pathlib import Path

BASE = Path(__file__).parent

def main():
    # Read source files
    glance = yaml.safe_load((BASE / 'glance.yml').read_text())
    server_page = yaml.safe_load((BASE / 'server.yml').read_text())

    # Build full config: Home, Server, Social
    full_config = {
        'server': glance['server'],
        'theme': glance['theme'],
        'pages': [
            glance['pages'][0],   # Home page
            server_page,          # Server page
            glance['pages'][1],   # Social page
        ],
    }

    # Serialize inner config
    inner_yaml = yaml.dump(full_config, default_flow_style=False, sort_keys=False, width=120, allow_unicode=True)

    # Validate round-trip
    verified = yaml.safe_load(inner_yaml)
    assert len(verified['pages']) == 3, f"Expected 3 pages, got {len(verified['pages'])}"
    assert verified['pages'][0]['name'] == 'Home'
    assert verified['pages'][1]['name'] == 'Server'
    assert verified['pages'][2]['name'] == 'Social'

    # Build ConfigMap with block scalars for readability
    cm = f"""apiVersion: v1
kind: ConfigMap
metadata:
  name: glance-config
  namespace: glance
data:
  glance.yml: |
{chr(10).join('    ' + line for line in inner_yaml.splitlines())}
"""

    # Validate the ConfigMap YAML
    cm_parsed = yaml.safe_load(cm)
    g = yaml.safe_load(cm_parsed['data']['glance.yml'])
    assert len(g['pages']) == 3

    # Write
    (BASE / 'configmap.yaml').write_text(cm)
    print(f"✅ ConfigMap regenerated: {len(g['pages'])} pages, {len(cm)} bytes")
    print(f"   Pages: {[p['name'] for p in g['pages']]}")

if __name__ == '__main__':
    main()
