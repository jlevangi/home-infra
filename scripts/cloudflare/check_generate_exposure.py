#!/usr/bin/env python3
"""Single assert-based behavioral check for the exposure generator."""

import importlib.util
from pathlib import Path

path = Path(__file__).with_name("generate_exposure.py")
spec = importlib.util.spec_from_file_location("generate_exposure", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

def ingress(name, value, host, path="/"):
    return f'''apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {name}
  annotations:
    cloudflare-tunnel.levangie.dev/exposure: {value}
spec:
  rules:
  - host: {host}
    http:
      paths:
      - path: {path}
        pathType: Prefix
        backend:
          service:
            name: example
            port:
              number: 80
''' + "\n---\n"

private = '''apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: default-private
spec:
  rules:
  - host: private.levangie.dev
'''
result = module.generate(ingress("public", "external", "public.levangie.dev") + private, set())
assert list(result["exposure_routes"]) == ["public.levangie.dev"]
route = result["exposure_routes"]["public.levangie.dev"]
assert route["service"] == module.ORIGIN and route["http_host_header"] == route["origin_server_name"] == route["hostname"]
assert route["no_tls_verify"] is False and route["zone"] == "levangie.dev"

def rejects(rendered, legacy=()):
    try:
        module.generate(rendered, set(legacy))
    except ValueError:
        return
    raise AssertionError("unsafe or malformed exposure accepted")

rejects(ingress("bad-annotation", "sometimes", "bad.levangie.dev"))
rejects(ingress("outside-zone", "external", "bad.example.org"))
rejects(ingress("legacy", "external", "old.levangie.dev"), ["old.levangie.dev"])
rejects(ingress("internal-legacy", "internal", "old.levangie.dev"), ["old.levangie.dev"])
assert module.generate(ingress("internal", "internal", "private.levangie.dev"), set())["exposure_routes"] == {}
assert module.generate(ingress("internal-a", "internal", "private.levangie.dev") + ingress("internal-b", "internal", "private.levangie.dev"), set())["exposure_routes"] == {}
rejects(ingress("external-a", "external", "same.levangie.dev", "/a") + ingress("external-b", "external", "same.levangie.dev", "/b"))
rejects(ingress("external", "external", "same.levangie.dev") + ingress("internal", "internal", "same.levangie.dev"))
