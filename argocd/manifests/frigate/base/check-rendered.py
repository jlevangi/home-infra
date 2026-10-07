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
    "containerPort: 8971",
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
for expected in (
    "name: frigate-oauth2-proxy-alpha-",
    "uri: http://127.0.0.1:8971",
    "frigate_roles",
    "frigate-admin",
    "X-Proxy-Secret",
    "auth_secret: \"{FRIGATE_PROXY_SECRET}\"",
    "frigate.levangie.dev/proxy: \"true\"",
    "additionalClaims:\n          - frigate_roles",
    "name: alpha-config\n      - name: config-data\n        persistentVolumeClaim:\n          claimName: frigate-config",
    "containerPort: 4180",
    "containerPort: 8971",
    "port: 4180\n    protocol: TCP\n    targetPort: proxy-http",
    "name: frigate\n            port:\n              number: 4180",
):
    assert expected in rendered, f"rendered manifests missing {expected!r}"
assert "name: frigate-oauth2-proxy\n  namespace: frigate\nspec:" not in rendered, "standalone proxy resources must not render"
assert "app: frigate-oauth2-proxy" not in rendered, "standalone proxy selector must not render"
# assert "containerPort: 5000" not in rendered, "Frigate 5000 must not be exposed as a container port"
# assert "port: 8971\n    protocol: TCP" not in rendered, "Service must not expose Frigate 8971"
assert "property: OIDC_CLIENT_SECRET" in rendered
assert "property: OAUTH2_PROXY_COOKIE_SECRET" in rendered
assert "property: FRIGATE_PROXY_SECRET" in rendered
assert "cidr: 172.20.20.104/32" not in rendered, "No node-IP bypass allowances are permitted"
print("ok: rendered Frigate baseline, OAuth2 proxy, secret references, and ingress validated")
