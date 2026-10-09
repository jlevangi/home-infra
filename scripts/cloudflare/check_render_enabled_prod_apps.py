#!/usr/bin/env python3
"""Single assert-based behavioral check for the production app renderer."""

import importlib.util
import subprocess
from pathlib import Path

path = Path(__file__).with_name("render_enabled_prod_apps.py")
spec = importlib.util.spec_from_file_location("render_enabled_prod_apps", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

apps_dir = Path(__file__).resolve().parents[2] / "argocd" / "apps" / "prod"
with subprocess.Popen(
    [str(path), "--apps", str(apps_dir), "--output", "/tmp/cloudflare-exposure-render"],
    stdout=subprocess.DEVNULL,
) as process:
    assert process.wait() == 0
