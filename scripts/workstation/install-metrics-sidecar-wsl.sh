#!/bin/bash
# install-metrics-sidecar-wsl.sh
# Installs the llama-swap metrics aggregator sidecar as a user systemd
# service inside WSL2 on pierce-pc. Idempotent — re-run safely after
# pulling an update to argocd/manifests/llama-cpp/base/sidecar-exporter.py.
#
# Companion to scripts/workstation/install-llama-swap-windows.ps1 (Step 1).
# Documented in docs/WSL/LLM/setup.md.

set -e

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PROJECT_ROOT="$(cd "$_SCRIPT_DIR/../.." && pwd)"

CANONICAL_SCRIPT="$_PROJECT_ROOT/argocd/manifests/llama-cpp/base/sidecar-exporter.py"
INSTALLED_SCRIPT="$HOME/.local/bin/llama-metrics-sidecar.py"
UNIT_PATH="$HOME/.config/systemd/user/llama-metrics-sidecar.service"

# Workstation llama-swap binds to :9080 (set by the Start Llama-Swap.lnk
# shortcut); the canonical sidecar defaults to :8080 because that matches
# the in-cluster Service port.
LLAMASWAP_URL='http://127.0.0.1:9080'

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; DGRAY='\033[1;30m'; CYAN='\033[0;36m'; NC='\033[0m'
section() { printf "\n${CYAN}=== %s ===${NC}\n" "$*"; }
ok()      { printf "  ${GREEN}ok  ${NC} %s\n" "$*"; }
do_()     { printf "  ${YELLOW}do  ${NC} %s\n" "$*"; }
skip()    { printf "  ${DGRAY}skip${NC} %s\n" "$*"; }

section 'preconditions'
[[ -f "$CANONICAL_SCRIPT" ]] || { echo "canonical script missing at $CANONICAL_SCRIPT — are you running from the repo?" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 not on PATH inside WSL2" >&2; exit 1; }
command -v systemctl >/dev/null || { echo "systemctl not present — is systemd enabled in WSL2?" >&2; exit 1; }
ok "canonical script:     $CANONICAL_SCRIPT"
ok "python3:              $(python3 --version)"
ok "systemd user manager: $(systemctl --user is-system-running 2>/dev/null || echo 'starting')"

section 'install / refresh script'
mkdir -p "$(dirname "$INSTALLED_SCRIPT")"
# Use a tmpfile + mv so the swap is atomic and re-running this script while
# the service is running doesn't leave a half-written file
TMP="$(mktemp)"
sed "s|^LLAMASWAP = \"http://localhost:8080\"|LLAMASWAP = \"$LLAMASWAP_URL\"|" "$CANONICAL_SCRIPT" > "$TMP"
if [[ -f "$INSTALLED_SCRIPT" ]] && cmp -s "$TMP" "$INSTALLED_SCRIPT"; then
    skip "script already up to date at $INSTALLED_SCRIPT"
    rm -f "$TMP"
    SCRIPT_CHANGED=false
else
    do_  "writing $INSTALLED_SCRIPT (LLAMASWAP=$LLAMASWAP_URL)"
    mv "$TMP" "$INSTALLED_SCRIPT"
    chmod 0555 "$INSTALLED_SCRIPT"
    SCRIPT_CHANGED=true
fi
ok "$INSTALLED_SCRIPT"

section 'systemd user unit'
mkdir -p "$(dirname "$UNIT_PATH")"
NEW_UNIT="$(cat <<'EOF'
[Unit]
Description=llama-swap metrics aggregator (workstation)
Documentation=https://github.com/jlevangi/home-infra/blob/main/argocd/manifests/llama-cpp/base/sidecar-exporter.py
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
# stdlib-only Python; talks to llama-swap.exe on Windows via the
# mirrored-networking loopback (127.0.0.1:9080) and exposes /metrics
# on 0.0.0.0:9090 which the cluster's ScrapeConfig pulls as
# pierce-pc.levangie.org:9090.
ExecStart=/usr/bin/python3 %h/.local/bin/llama-metrics-sidecar.py
Restart=always
RestartSec=10
# Keep stdout/stderr in journald for `journalctl --user -u llama-metrics-sidecar`
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF
)"
UNIT_CHANGED=true
if [[ -f "$UNIT_PATH" ]] && [[ "$(cat "$UNIT_PATH")" == "$NEW_UNIT" ]]; then
    skip "unit already up to date at $UNIT_PATH"
    UNIT_CHANGED=false
else
    do_  "writing $UNIT_PATH"
    printf '%s\n' "$NEW_UNIT" > "$UNIT_PATH"
fi

section 'enable + start'
systemctl --user daemon-reload
if systemctl --user is-enabled --quiet llama-metrics-sidecar.service; then
    skip 'service already enabled'
else
    do_ 'systemctl --user enable llama-metrics-sidecar.service'
    systemctl --user enable llama-metrics-sidecar.service
fi
# Always (re)start when script or unit changed, otherwise just ensure active
if $SCRIPT_CHANGED || $UNIT_CHANGED; then
    do_ 'restart service (script or unit changed)'
    systemctl --user restart llama-metrics-sidecar.service
elif ! systemctl --user is-active --quiet llama-metrics-sidecar.service; then
    do_ 'start service (was not active)'
    systemctl --user start llama-metrics-sidecar.service
else
    skip 'service already active and current'
fi

section 'linger (survives logout / reboot)'
if loginctl show-user "$USER" 2>/dev/null | grep -q '^Linger=yes$'; then
    skip "linger already enabled for $USER"
else
    do_ "sudo loginctl enable-linger $USER  (may prompt for password)"
    if sudo -n true 2>/dev/null; then
        sudo loginctl enable-linger "$USER"
    else
        echo "    sudo requires a password — run manually if you skipped this:" >&2
        echo "      sudo loginctl enable-linger $USER" >&2
        sudo loginctl enable-linger "$USER" || echo "    (linger NOT enabled — sidecar will stop at logout/reboot)" >&2
    fi
fi

section 'sanity'
sleep 1
ok "service: $(systemctl --user is-active llama-metrics-sidecar.service)"
HEALTH=$(curl -s --max-time 3 http://127.0.0.1:9090/healthz 2>&1 || echo 'FAIL')
ok "healthz: $HEALTH"
ok "next:    bash $_SCRIPT_DIR/verify-setup.sh  (end-to-end check)"
