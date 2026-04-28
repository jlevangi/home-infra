#!/usr/bin/env bash
set -euo pipefail

KUBECTL_CONTEXT="${KUBECTL_CONTEXT:-k3s-prod}"
SOURCE_NAMESPACE="${SOURCE_NAMESPACE:-vault}"
SOURCE_POD="${SOURCE_POD:-vault-0}"
SOURCE_SECRET_NAME="${SOURCE_SECRET_NAME:-vault-init}"
SOURCE_ADDR="${SOURCE_ADDR:-http://127.0.0.1:8200}"
DEST_NAMESPACE="${DEST_NAMESPACE:-vault-raft}"
DEST_POD="${DEST_POD:-vault-raft-0}"
DEST_SECRET_NAME="${DEST_SECRET_NAME:-vault-init}"
DEST_ADDR="${DEST_ADDR:-http://vault-raft.vault-raft.svc:8200}"
KV_MOUNT="${KV_MOUNT:-kv}"
ENVIRONMENTS="${ENVIRONMENTS:-prod stage test talos-test}"
DRY_RUN="${DRY_RUN:-false}"

require_bin() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_bin kubectl
require_bin jq

SOURCE_TOKEN="$(kubectl --context "$KUBECTL_CONTEXT" get secret "$SOURCE_SECRET_NAME" -n "$SOURCE_NAMESPACE" -o jsonpath='{.data.root-token}' | base64 -d)"
DEST_TOKEN="$(kubectl --context "$KUBECTL_CONTEXT" get secret "$DEST_SECRET_NAME" -n "$DEST_NAMESPACE" -o jsonpath='{.data.root-token}' | base64 -d)"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

source_vault() {
  kubectl --context "$KUBECTL_CONTEXT" exec -n "$SOURCE_NAMESPACE" "$SOURCE_POD" -- \
    sh -ec "export VAULT_ADDR='$SOURCE_ADDR' VAULT_TOKEN='$SOURCE_TOKEN'; $*"
}

dest_vault_put() {
  local path="$1"
  local payload_file="$2"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "Would copy ${KV_MOUNT}/${path}"
    return 0
  fi

  kubectl --context "$KUBECTL_CONTEXT" exec -i -n "$DEST_NAMESPACE" "$DEST_POD" -- \
    sh -ec "cat > /tmp/vault-kv-payload.json && export VAULT_ADDR='$DEST_ADDR' VAULT_TOKEN='$DEST_TOKEN'; vault kv put -mount='$KV_MOUNT' '$path' @/tmp/vault-kv-payload.json >/dev/null && rm -f /tmp/vault-kv-payload.json" < "$payload_file"
}

copy_secret() {
  local path="$1"
  local payload_file="$TMP_DIR/payload.json"

  echo "Copying ${KV_MOUNT}/${path}"
  source_vault "vault kv get -format=json -mount='$KV_MOUNT' '$path'" | jq '.data.data' > "$payload_file"
  dest_vault_put "$path" "$payload_file"
}

walk_prefix() {
  local prefix="$1"
  local children

  if ! children="$(source_vault "vault kv list -format=json -mount='$KV_MOUNT' '$prefix'" 2>/dev/null)"; then
    echo "Skipping empty or missing prefix ${KV_MOUNT}/${prefix}" >&2
    return 0
  fi

  while IFS= read -r child; do
    [[ -z "$child" ]] && continue
    if [[ "$child" == */ ]]; then
      walk_prefix "${prefix%/}/${child%/}"
    else
      copy_secret "${prefix%/}/${child}"
    fi
  done < <(jq -r '.[]' <<<"$children")
}

echo "Migrating Vault KV data from ${SOURCE_NAMESPACE}/${SOURCE_POD} to ${DEST_NAMESPACE}/${DEST_POD} on context ${KUBECTL_CONTEXT}"

for env_name in $ENVIRONMENTS; do
  walk_prefix "$env_name"
done

echo "Vault KV migration complete"
