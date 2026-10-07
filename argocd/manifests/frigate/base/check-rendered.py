#!/usr/bin/env python3
"""Minimal static guard for the rendered Frigate GitOps manifests."""
import subprocess

rendered = subprocess.check_output(["kubectl", "kustomize", "argocd/manifests/frigate/base"], text=True)
for expected in (
    "kind: Deployment\nmetadata:\n  name: frigate\n",
    "replicas: 1\n",
    "type: Recreate\n",
    "homelab.levangie.dev/compute-tier: performance",
    "ghcr.io/blakeblackshear/frigate:0.18.0@sha256:9678a83a76e4730ac7d9ea7428370e32ae656d6b312aaad30d6c69f3fef14d35",
    "storage: 10Gi",
    "server: 172.20.20.5",
    "path: /volume1/surveillance",
    "subPath: frigate",
    "sizeLimit: 256Mi",
    "sizeLimit: 1Gi",
    "port: 8971",
    "tls:\n      enabled: false\n\n    mqtt:",
    "property: FRIGATE_MQTT_USER",
    "property: FRIGATE_MQTT_PASSWORD",
    "host: frigate.levangie.dev",
    "secretName: frigate-tls",
    "{FRIGATE_MQTT_USER}",
    "{FRIGATE_MQTT_PASSWORD}",
    "name: frigate-config-",
):
    assert expected in rendered, f"rendered manifests missing {expected!r}"
assert "${FRIGATE_MQTT_USER}" not in rendered and "${FRIGATE_MQTT_PASSWORD}" not in rendered
assert "nvidia.com/gpu" not in rendered and "runtimeClassName: nvidia" not in rendered
print("ok: rendered Frigate image, single-Recreate placement, secrets, PVC/NFS/tmpfs, private service, and ingress validated")
