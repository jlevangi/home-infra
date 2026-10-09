#!/usr/bin/env python3
"""Generate Terraform tunnel routes from already-rendered production Ingress YAML."""

import argparse
import json
import re
import sys
from pathlib import Path

import yaml

ANNOTATION = "cloudflare-tunnel.levangie.dev/exposure"
DOMAIN = re.compile(r"(?=.{1,253}\Z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\Z")
ORIGIN = "https://k3s-prod.levangie.dev"
PERMITTED_ZONES = {"levangie.dev"}


def generate(rendered, legacy_hosts):
    routes, exposures = {}, {}
    for obj in yaml.safe_load_all(rendered):
        if obj is None:
            continue
        if not isinstance(obj, dict):
            raise ValueError("rendered YAML document must be a mapping")
        if obj.get("kind") != "Ingress":
            continue
        metadata = obj.get("metadata")
        if not isinstance(metadata, dict):
            raise ValueError("Ingress metadata must be a mapping")
        name = metadata.get("name", "<unnamed>")
        annotations = metadata.get("annotations", {})
        if not isinstance(annotations, dict):
            raise ValueError(f"{name}: annotations must be a mapping")
        exposure = annotations.get(ANNOTATION)
        if exposure not in (None, "external", "internal"):
            raise ValueError(f"{name}: invalid {ANNOTATION} value {exposure!r}")
        spec = obj.get("spec")
        if not isinstance(spec, dict):
            if exposure:
                raise ValueError(f"{name}: marked Ingress must have a spec mapping")
            continue
        rules = spec.get("rules", [])
        if not isinstance(rules, list):
            raise ValueError(f"{name}: Ingress rules must be a list")
        if exposure and not rules:
            raise ValueError(f"{name}: marked Ingress must have host rules")
        for rule in rules:
            if not isinstance(rule, dict):
                if exposure:
                    raise ValueError(f"{name}: Ingress rule must be a mapping")
                continue
            host = rule.get("host")
            if not isinstance(host, str) or not DOMAIN.fullmatch(host):
                if exposure:
                    raise ValueError(f"{name}: invalid Ingress host {host!r}")
                continue
            prior = exposures.setdefault(host, exposure)
            if prior != exposure and "external" in (prior, exposure):
                raise ValueError(f"{name}: conflicting exposure annotations for host {host}")
            if exposure == "internal" and host in legacy_hosts:
                raise ValueError(f"{name}: internal annotation conflicts with legacy tunnel route {host}; migrate the legacy route explicitly")
            if exposure != "external":
                continue
            zone = next((zone for zone in PERMITTED_ZONES if host.endswith("." + zone)), None)
            if zone is None:
                raise ValueError(f"{name}: external host is outside the permitted zone: {host}")
            if host in legacy_hosts:
                raise ValueError(f"{name}: external host conflicts with legacy tunnel route: {host}")
            if host in routes:
                raise ValueError(f"{name}: duplicate external host {host}; tunnel routes expose every path for a hostname")
            http = rule.get("http")
            paths = http.get("paths") if isinstance(http, dict) else None
            if not isinstance(paths, list) or not paths or any(not isinstance(path, dict) or not isinstance(path.get("path"), str) or not isinstance(path.get("pathType"), str) for path in paths):
                raise ValueError(f"{name}: external host {host} has malformed or missing HTTP paths")
            routes[host] = {
                "zone": zone,
                "hostname": host,
                "service": ORIGIN,
                "http_host_header": host,
                "origin_server_name": host,
                "no_tls_verify": False,
            }
    return {"exposure_routes": routes}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-dir", type=Path, required=True, help="Directory of successfully rendered enabled production manifests")
    parser.add_argument("--terraform", type=Path, required=True, help="Terraform file containing legacy static routes")
    parser.add_argument("--output", type=Path, required=True, help="Destination .tfvars.json (written atomically)")
    parser.add_argument("--report", type=Path, required=True, help="Destination JSON report (written atomically)")
    parser.add_argument("--origin", default=ORIGIN, help="Shared HTTPS origin")
    args = parser.parse_args()
    args.output.unlink(missing_ok=True)
    try:
        if not args.input_dir.is_dir():
            raise ValueError("rendered input directory does not exist")
        files = sorted(path for path in args.input_dir.rglob("*") if path.is_file() and path.suffix.lower() in (".yaml", ".yml"))
        if not files:
            raise ValueError("rendered input directory contains no YAML manifests")
        if args.origin != ORIGIN:
            raise ValueError("origin must match the configured shared origin")
        rendered = "\n---\n".join(path.read_text(encoding="utf-8") for path in files)
        terraform = args.terraform.read_text(encoding="utf-8")
        legacy_hosts = set(re.findall(r'\bhostname\s*=\s*"([^" ]+)"', terraform))
        result = generate(rendered, legacy_hosts)
        payload = json.dumps(result, sort_keys=True, indent=2) + "\n"
        report = json.dumps({"status": "ok", "count": len(result["exposure_routes"])}, sort_keys=True, indent=2) + "\n"
        for path, content in ((args.output, payload), (args.report, report)):
            path.parent.mkdir(parents=True, exist_ok=True)
            temporary = path.with_suffix(path.suffix + ".tmp")
            temporary.write_text(content, encoding="utf-8")
            temporary.replace(path)
    except (OSError, ValueError, yaml.YAMLError) as error:
        print(f"exposure generation failed: {error}", file=sys.stderr)
        args.output.unlink(missing_ok=True)
        try:
            args.report.parent.mkdir(parents=True, exist_ok=True)
            temporary = args.report.with_suffix(args.report.suffix + ".tmp")
            temporary.write_text(json.dumps({"status": "error"}, sort_keys=True, indent=2) + "\n", encoding="utf-8")
            temporary.replace(args.report)
        except OSError as report_error:
            print(f"could not write failure report: {report_error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
