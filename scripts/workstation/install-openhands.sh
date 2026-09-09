#!/usr/bin/env bash
set -euo pipefail

OPENHANDS_VERSION=1.16.0
OAUTH2_PROXY_VERSION=7.9.0
OPENHANDS_PORT=8010
CONFIG_DIR="$HOME/.config"
SYSTEMD_DIR="$CONFIG_DIR/systemd/user"
ENV_FILE="$CONFIG_DIR/openhands.env"
OAUTH_ENV_FILE="$CONFIG_DIR/openhands-oauth2-proxy.env"

for file in "$ENV_FILE" "$OAUTH_ENV_FILE"; do
  [[ -s "$file" ]] || { echo "Missing $file; restore kv/prod/openhands before installation." >&2; exit 1; }
done

npm install -g "@openhands/agent-canvas@${OPENHANDS_VERSION}"
mkdir -p "$HOME/.local/bin" "$SYSTEMD_DIR" "$HOME/.openhands"
oauth_tmp=$(mktemp "$HOME/.local/bin/oauth2-proxy.XXXXXX")
trap 'rm -f "$oauth_tmp"' EXIT
curl -fsSL "https://github.com/oauth2-proxy/oauth2-proxy/releases/download/v${OAUTH2_PROXY_VERSION}/oauth2-proxy-v${OAUTH2_PROXY_VERSION}.linux-amd64.tar.gz" |
  tar -xzO "oauth2-proxy-v${OAUTH2_PROXY_VERSION}.linux-amd64/oauth2-proxy" >"$oauth_tmp"
chmod 755 "$oauth_tmp"
mv -f "$oauth_tmp" "$HOME/.local/bin/oauth2-proxy"
trap - EXIT
chmod 700 "$HOME/.openhands"
chmod 600 "$ENV_FILE" "$OAUTH_ENV_FILE"

cat >"$SYSTEMD_DIR/openhands.service" <<EOF
[Unit]
Description=OpenHands Agent Canvas
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$HOME/git
EnvironmentFile=$ENV_FILE
Environment=PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=$HOME/.local/bin/agent-canvas --port $OPENHANDS_PORT
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=$HOME/.openhands $HOME/git

[Install]
WantedBy=default.target
EOF

write_proxy() {
  local name=$1 listen=$2 upstream=$3 host=$4 cookie=$5
  cat >"$SYSTEMD_DIR/${name}.service" <<EOF
[Unit]
Description=oauth2-proxy for $host
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=$OAUTH_ENV_FILE
ExecStart=$HOME/.local/bin/oauth2-proxy --provider=keycloak-oidc --oidc-issuer-url=https://auth.levangie.org/realms/master --client-id=openhands --redirect-url=https://$host/oauth2/callback --http-address=0.0.0.0:$listen --upstream=http://127.0.0.1:$upstream --email-domain=* --cookie-name=$cookie --cookie-secure=true --cookie-samesite=lax --cookie-domain=$host --whitelist-domain=$host --reverse-proxy=true --skip-provider-button=true --pass-access-token=true --pass-authorization-header=true
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict

[Install]
WantedBy=default.target
EOF
}

write_proxy openhands-oauth2-proxy 4180 "$OPENHANDS_PORT" openhands.levangie.dev _oauth2_proxy
write_proxy openhands-preview-3000 4300 3000 3000.openhands.levangie.dev _oauth2_proxy_3000
write_proxy openhands-preview-5173 4473 5173 5173.openhands.levangie.dev _oauth2_proxy_5173
write_proxy openhands-preview-8001 4801 8001 8001.openhands.levangie.dev _oauth2_proxy_8001

systemctl --user daemon-reload
systemctl --user enable --now openhands.service openhands-oauth2-proxy.service \
  openhands-preview-3000.service openhands-preview-5173.service openhands-preview-8001.service

for _ in {1..45}; do
  curl -fsS "http://127.0.0.1:${OPENHANDS_PORT}/health" >/dev/null && break
  sleep 2
done
curl -fsS "http://127.0.0.1:${OPENHANDS_PORT}/health"
echo
systemctl --user is-active openhands openhands-oauth2-proxy \
  openhands-preview-3000 openhands-preview-5173 openhands-preview-8001
