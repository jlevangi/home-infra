#!/usr/bin/env bash
# RustDesk Linux installer pre-configured for the home-infra self-hosted server.
#
# Usage (run on the target Linux Mint / Debian / Ubuntu machine):
#   curl -fsSL https://raw.githubusercontent.com/jlevangi/home-infra/main/scripts/rustdesk/install-linux.sh | sudo bash
#
# After this finishes:
#   1. Open RustDesk on this machine.
#   2. (Optional) Settings -> Security -> Set Permanent Password
#      so the controller can reconnect without a phone call.
#   3. The Device ID printed at the end goes into your address book.

set -euo pipefail

RUSTDESK_VERSION="1.4.7"
SERVER_HOST="rustdesk.levangie.dev"
SERVER_KEY="3V8rnL1ol+2F16Vaz7on0tD0aY4pdbbh3N2TYo500Cs="

if [[ $EUID -ne 0 ]]; then
  echo "Run as root (use 'sudo bash')." >&2
  exit 1
fi

case "$(dpkg --print-architecture 2>/dev/null || uname -m)" in
  amd64|x86_64) DEB_ARCH="x86_64" ;;
  arm64|aarch64) DEB_ARCH="aarch64" ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

DEB_URL="https://github.com/rustdesk/rustdesk/releases/download/${RUSTDESK_VERSION}/rustdesk-${RUSTDESK_VERSION}-${DEB_ARCH}.deb"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Downloading RustDesk ${RUSTDESK_VERSION} (${DEB_ARCH})"
curl -fsSL "$DEB_URL" -o "$TMP/rustdesk.deb"

echo "==> Installing package (apt resolves deps)"
apt-get update -qq
apt-get install -y "$TMP/rustdesk.deb"

echo "==> Stopping rustdesk service before writing config"
systemctl stop rustdesk 2>/dev/null || true

write_config() {
  local cfg_home="$1"
  local cfg_dir="${cfg_home}/.config/rustdesk"
  mkdir -p "$cfg_dir"
  cat >"$cfg_dir/RustDesk2.toml" <<TOML
rendezvous_server = '${SERVER_HOST}'
nat_type = 0
serial = 0

[options]
'custom-rendezvous-server' = '${SERVER_HOST}'
'relay-server' = '${SERVER_HOST}'
'api-server' = ''
key = '${SERVER_KEY}'
TOML
  if [[ "$cfg_home" != "/root" ]]; then
    local user
    user="$(basename "$cfg_home")"
    chown -R "${user}:${user}" "$cfg_dir"
  fi
}

echo "==> Writing server settings to /root and each user home"
write_config /root
for home in /home/*; do
  [[ -d "$home" ]] || continue
  write_config "$home"
done

echo "==> Enabling rustdesk service for unattended access"
systemctl enable rustdesk
systemctl start rustdesk

echo "==> Waiting for service to settle"
sleep 5

echo ""
echo "===================================================================="
echo " RustDesk ${RUSTDESK_VERSION} installed and pointed at ${SERVER_HOST}"
echo "===================================================================="
ID="$(rustdesk --get-id 2>/dev/null || true)"
if [[ -n "$ID" ]]; then
  echo " Device ID: $ID"
else
  echo " Device ID: (could not auto-detect; open RustDesk to see it)"
fi
echo ""
echo " Next steps:"
echo "   1. Launch RustDesk on this machine (or wait for it on next login)."
echo "   2. Optional: Settings -> Security -> set a permanent password so"
echo "      the controller can reconnect without prompting each time."
echo "   3. Add the Device ID above to your address book on the controller."
echo "===================================================================="
