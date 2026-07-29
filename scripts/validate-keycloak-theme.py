#!/usr/bin/env python3
"""Validate the CSS-first LeVangie Keycloak login theme contract."""

from __future__ import annotations

import hashlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
THEME = ROOT / "argocd/manifests/keycloak/base/theme/login"
EXPECTED = {
    "theme.properties",
    "resources/css/levangie.css",
    "resources/img/levangie-dev.png",
    "messages/messages_en.properties",
}
ALLOWED_MESSAGES = {
    "loginAccountTitle",
    "loginTitle",
    "doLogIn",
    "webauthn-doAuthenticate",
    "passkey-doAuthenticate",
    "emailForgotTitle",
    "emailInstruction",
    "backToLogin",
    "errorTitle",
    "pageExpiredTitle",
}
LOGO_SHA256 = "2566115dc5eafef6f811d3e823fba58f2939d24d3220d88f1a9c7d0cbb5c2907"


def fail(message: str) -> None:
    raise ValueError(message)


def strict_properties(path: Path) -> list[tuple[str, str]]:
    """Parse the deliberately restricted key=value subset used by this theme."""
    result = []
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith(('#', '!')):
            continue
        if "=" not in line:
            fail(f"{path}:{number}: expected key=value")
        key, value = line.split("=", 1)
        result.append((key.strip(), value.strip()))
    return result


def main() -> None:
    actual = {
        str(path.relative_to(THEME))
        for path in THEME.rglob("*")
        if path.is_file() or path.is_symlink()
    }
    missing = sorted(EXPECTED - actual)
    unexpected = sorted(actual - EXPECTED)
    if missing:
        fail("missing theme files: " + ", ".join(missing))
    if unexpected:
        fail("unexpected theme files (v1 permits no templates, scripts, or extra assets): " + ", ".join(unexpected))
    for name in EXPECTED:
        if (THEME / name).is_symlink():
            fail(f"theme files must not be symlinks: {name}")

    theme_entries = strict_properties(THEME / "theme.properties")
    theme_props = dict(theme_entries)
    if len(theme_props) != len(theme_entries):
        fail("theme.properties contains duplicate keys")
    expected_props = {"parent", "styles", "darkMode", "favicons.logo", "favicons.logo.type"}
    if set(theme_props) != expected_props:
        fail("theme.properties keys must be exactly: " + ", ".join(sorted(expected_props)))
    if theme_props["parent"] != "keycloak.v2":
        fail("theme parent must be keycloak.v2")
    if theme_props["darkMode"] != "false":
        fail("theme darkMode must be false")
    if theme_props["favicons.logo.type"] != "image/png":
        fail("favicon type must be image/png")
    styles = theme_props["styles"].split()
    if styles != ["css/styles.css", "css/levangie.css"]:
        fail("styles must load inherited css/styles.css then css/levangie.css")
    # css/styles.css is supplied by the inherited keycloak.v2 theme.
    for reference in styles[1:]:
        if not (THEME / "resources" / reference).is_file():
            fail(f"missing stylesheet reference: {reference}")
    favicon = theme_props.get("favicons.logo")
    if not favicon or not (THEME / "resources" / favicon).is_file():
        fail(f"missing favicon reference: {favicon}")

    css_path = THEME / "resources/css/levangie.css"
    css = css_path.read_text(encoding="utf-8")
    lower = css.lower()
    prohibited = {
        r"@import\b": "CSS import",
        r"outline\s*:\s*none\b": "removed outline",
        r"transition\s*:\s*all\b": "transition: all",
        r"user-scalable\s*=\s*no": "disabled zoom",
        r"maximum-scale\s*=\s*1(?:\.0*)?\b": "disabled zoom",
        r"(?:linear|radial|conic)-gradient\s*\(": "gradient",
        r"backdrop-filter\s*:": "glass effect",
    }
    for pattern, label in prohibited.items():
        if re.search(pattern, lower):
            fail(f"{css_path}: prohibited {label}")
    if not re.search(r"@media\s*\(max-width\s*:\s*48rem\)", css, re.I):
        fail("missing 48rem responsive media query")
    if not re.search(r"@media\s*\(prefers-reduced-motion\s*:\s*reduce\)", css, re.I):
        fail("missing reduced-motion media query")
    # Deliberately permit only simple, relative, unescaped CSS url() values.
    for reference in re.findall(r"url\(\s*['\"]?([^'\")]+)", css, re.I):
        if re.match(r"(?i)(?:https?:)?//|data:", reference):
            fail(f"prohibited non-local CSS asset: {reference[:40]}")
        target = (css_path.parent / reference).resolve()
        if THEME.resolve() not in target.parents or not target.is_file():
            fail(f"unsafe or missing CSS asset: {reference}")

    logo = THEME / "resources/img/levangie-dev.png"
    if hashlib.sha256(logo.read_bytes()).hexdigest() != LOGO_SHA256:
        fail(f"{logo}: content does not match the approved optimized logo")
    for svg in THEME.rglob("*.svg"):
        text = svg.read_text(encoding="utf-8").lower()
        if re.search(r"(?:href|src)\s*=\s*['\"]\s*(?:https?:)?//|<script|onload\s*=", text):
            fail(f"{svg}: unsafe SVG content")

    message_entries = strict_properties(THEME / "messages/messages_en.properties")
    keys = [key for key, _ in message_entries]
    duplicates = sorted({key for key in keys if keys.count(key) > 1})
    if duplicates:
        fail("duplicate message keys: " + ", ".join(duplicates))
    unknown = sorted(set(keys) - ALLOWED_MESSAGES)
    if unknown:
        fail("message keys outside the Keycloak 26.7 approved allowlist: " + ", ".join(unknown))
    if set(keys) != ALLOWED_MESSAGES:
        fail("approved message keys missing: " + ", ".join(sorted(ALLOWED_MESSAGES - set(keys))))

    print("Keycloak theme validation passed")


if __name__ == "__main__":
    try:
        main()
    except (OSError, UnicodeError, ValueError) as error:
        print(f"Keycloak theme validation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
