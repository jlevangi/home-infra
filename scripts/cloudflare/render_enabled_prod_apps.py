#!/usr/bin/env python3
"""Render locally sourced production Argo Applications for exposure discovery."""

import argparse
import os
import subprocess
import tempfile
from pathlib import Path

import yaml


def run(command, **kwargs):
    if "env" in kwargs:
        kwargs["env"] = {**os.environ, **kwargs["env"]}
    subprocess.run(command, check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apps", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    apps = sorted(args.apps.glob("*.yaml")) + sorted(args.apps.glob("*.yml"))
    if not apps:
        raise SystemExit("production Argo source directory contains no YAML")
    args.output.mkdir(parents=True, exist_ok=True)
    for old in args.output.iterdir():
        if old.is_file() and old.suffix.lower() in (".yaml", ".yml"):
            old.unlink()
    with tempfile.TemporaryDirectory() as temp:
        temp = Path(temp)
        for app_file in apps:
            for app in yaml.safe_load_all(app_file.read_text(encoding="utf-8")):
                if app is None or not isinstance(app, dict) or app.get("kind") != "Application":
                    continue
                spec, metadata = app.get("spec"), app.get("metadata")
                if not isinstance(spec, dict) or not isinstance(metadata, dict):
                    raise SystemExit(f"{app_file}: malformed Application")
                if "sources" in spec:
                    raise SystemExit(f"{app_file}: multi-source Applications are unsupported; refusing incomplete render")
                source = spec.get("source")
                if not isinstance(source, dict):
                    raise SystemExit(f"{app_file}: Application source is missing")
                name = metadata.get("name")
                destination = spec.get("destination", {})
                namespace = destination.get("namespace", "default") if isinstance(destination, dict) else "default"
                rendered = args.output / f"{name}.yaml"
                chart = source.get("chart")
                if chart:
                    repo, version = source.get("repoURL"), source.get("targetRevision")
                    if not repo or not version:
                        raise SystemExit(f"{app_file}: Helm Application lacks repository or chart version")
                    if repo.startswith("oci://"):
                        chart_ref = f"{repo}/{chart}"
                    elif repo.startswith("ghcr.io/"):
                        chart_ref = f"oci://{repo}/{chart}"
                    else:
                        chart_ref = None
                    if chart_ref:
                        command = ["helm", "template", name, chart_ref, "--version", version, "--namespace", namespace]
                    else:
                        command = ["helm", "template", name, chart, "--repo", repo, "--version", version, "--namespace", namespace]
                    helm = source.get("helm", {})
                    if not isinstance(helm, dict):
                        raise SystemExit(f"{app_file}: Helm configuration must be a mapping")
                    values = helm.get("values") or ""
                    values_object = helm.get("valuesObject")
                    if values_object is not None:
                        values_file = temp / f"{name}-values.yaml"
                        values_file.write_text(values, encoding="utf-8")
                        object_file = temp / f"{name}-values-object.yaml"
                        object_file.write_text(yaml.safe_dump(values_object, sort_keys=False), encoding="utf-8")
                        command.extend(["--values", str(values_file), "--values", str(object_file)])
                    elif values:
                        values_file = temp / f"{name}-values.yaml"
                        values_file.write_text(values, encoding="utf-8")
                        command.extend(["--values", str(values_file)])
                    if helm.get("valueFiles"):
                        raise SystemExit(f"{app_file}: Helm valueFiles are unsupported without the Argo multi-source renderer")
                    if helm.get("parameters"):
                        for parameter in helm["parameters"]:
                            command.extend(["--set-string" if parameter.get("forceString") else "--set", f"{parameter['name']}={parameter['value']}"])
                    if helm.get("fileParameters"):
                        raise SystemExit(f"{app_file}: Helm fileParameters are unsupported without the Argo multi-source renderer")
                    if helm.get("releaseName"):
                        command[2] = helm["releaseName"]
                    if helm.get("skipCrds"):
                        command.append("--skip-crds")
                    run(command, stdout=rendered.open("w", encoding="utf-8"))
                else:
                    repo_url, target, path = source.get("repoURL"), source.get("targetRevision"), source.get("path")
                    if not path:
                        raise SystemExit(f"{app_file}: source path is missing")
                    if repo_url in ("git@github.com:jlevangi/home-infra.git", "https://github.com/jlevangi/home-infra.git"):
                        if target != "main":
                            raise SystemExit(f"{app_file}: home-infra sources must track main")
                        root = Path(path)
                        if not (root / "kustomization.yaml").is_file() and not (root / "Kustomization").is_file():
                            raise SystemExit(f"{app_file}: source path is not a Kustomize directory")
                        run(["kubectl", "kustomize", str(root)], stdout=rendered.open("w", encoding="utf-8"))
                    else:
                        if repo_url != "https://github.com/CodeWithCJ/SparkyFitness.git":
                            raise SystemExit(f"{app_file}: unsupported external Git source; refusing incomplete render")
                        checkout = temp / f"{name}-source"
                        run(["git", "clone", "--quiet", "--depth", "1", "--branch", target, repo_url, str(checkout)])
                        chart_dir = checkout / path
                        if not (chart_dir / "Chart.yaml").is_file():
                            raise SystemExit(f"{app_file}: external source path is not a Helm chart")
                        helm = source.get("helm", {})
                        values = helm.get("values", "")
                        values_file = temp / f"{name}-values.yaml"
                        values_file.write_text(values, encoding="utf-8")
                        helm_home = temp / f"{name}-helm"
                        helm_home.mkdir()
                        helm_env = {"HELM_CONFIG_HOME": str(helm_home), "HELM_CACHE_HOME": str(helm_home / "cache"), "HELM_DATA_HOME": str(helm_home / "data")}
                        run(["helm", "repo", "add", "sparky-postgresql", "https://repo.helmforge.dev"], env=helm_env)
                        run(["helm", "dependency", "build", str(chart_dir)], env=helm_env)
                        run(["helm", "template", name, str(chart_dir), "--namespace", namespace, "--values", str(values_file)], stdout=rendered.open("w", encoding="utf-8"), env=helm_env)
    return 0


if __name__ == "__main__":
    main()
