# Proxmox Keycloak SSO runbook

Proxmox web login via Keycloak, alongside `root@pam`. Configured live, not from git:
Proxmox keeps realms and users in cluster-wide `/etc/pve`, and the Keycloak client lives in Keycloak's DB.

## Current state

| Piece | Value |
|---|---|
| Keycloak client | `proxmox` (confidential, `master` realm) |
| Client secret | Vault `kv/prod/proxmox-oidc` → `OIDC_CLIENT_SECRET` |
| Proxmox realm | `keycloak` — `openid`, issuer `https://auth.levangie.org/realms/master`, `--username-claim username`, `--autocreate 0`, comment `Keycloak SSO`, not default |
| Group | `admins` → `Administrator` on `/` |
| Users | `pierce@keycloak` (member of `admins`) |
| Redirect URIs | `https://proxmox.levangie.org/*`, plus `https://<node>.levangie.org:8006/*` and `https://<node-ip>:8006/*` for **every** node |

`root@pam` is break-glass: per-node password, works when Keycloak or the cluster network is down. Do not disable it.

With autocreate off, only users pre-created in Proxmox can log in; any other Keycloak user gets `authentication failure`.

## When a node is added or removed

Keycloak rejects logins from a node whose URL is not a registered redirect URI (`Invalid parameter: redirect_uri`). Re-sync the list after every `pvecm add` / `pvecm delnode`.

### Before joining a node

Joining **replaces the new node's `/etc/pve`** with the cluster copy (see the pre-join checklist in bd memory `pve-join-replaces-etc-pve-checklist`). The realm, group and users come from the cluster, so the new node inherits them — nothing to configure on it. Only the Keycloak redirect list needs updating.

### Re-sync redirect URIs

Run from a workstation with root SSH to atlas and a `kubectl` context for prod. Builds the list from live `pvecm` membership, so it covers adds and removals and is safe to re-run.

```bash
set -euo pipefail
NODES=$(ssh root@172.20.20.6 pvesh get /cluster/status --output-format json \
  | jq -r '.[]|select(.type=="node")|"\(.name) \(.ip)"')
URIS=$(echo "$NODES" | jq -Rn '["https://proxmox.levangie.org/*"]
  + [inputs|split(" ")|("https://\(.[0]).levangie.org:8006/*","https://\(.[1]):8006/*")]')
ORIGINS=$(echo "$URIS" | jq '[.[]|rtrimstr("/*")]')

KC_ADMIN_PASS=$(kubectl -n keycloak get secret keycloak-secrets \
  -o jsonpath='{.data.KEYCLOAK_ADMIN_PASSWORD}' | base64 -d)
TOKEN=$(curl -sS -X POST https://auth.levangie.org/realms/master/protocol/openid-connect/token \
  -d grant_type=password -d client_id=admin-cli -d username=admin \
  --data-urlencode "password=$KC_ADMIN_PASS" | jq -r .access_token)
unset KC_ADMIN_PASS
KC=https://auth.levangie.org/admin/realms/master
CID=$(curl -sS "$KC/clients?clientId=proxmox" -H "Authorization: Bearer $TOKEN" | jq -r '.[0].id')

curl -sS "$KC/clients/$CID" -H "Authorization: Bearer $TOKEN" \
  | jq --argjson u "$URIS" --argjson o "$ORIGINS" '.redirectUris=$u | .webOrigins=$o' \
  | curl -sS -o /dev/null -w 'PUT %{http_code}\n' -X PUT "$KC/clients/$CID" \
      -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d @-
curl -sS "$KC/clients/$CID" -H "Authorization: Bearer $TOKEN" | jq '.redirectUris'
```

Expect `PUT 204` and two URIs per node plus the `proxmox.levangie.org` entry. The admin token lives 60 s; re-run the token step if a call returns 401.

### Verify

1. Open `https://<new-node>.levangie.org:8006`, pick **Realm: Keycloak SSO**, click Login.
2. Expect the Keycloak sign-in page, not `Invalid parameter: redirect_uri`.
3. Sign in; the top-right shows `pierce@keycloak`.

### After removing a node

Run the re-sync above so the old node's URIs are dropped. Nothing else references the node.

## Grant or revoke access

```bash
# grant full admin to an existing Keycloak user
ssh root@172.20.20.6 pveum user add <keycloak-username>@keycloak --groups admins
# revoke
ssh root@172.20.20.6 pveum user delete <keycloak-username>@keycloak
```

`<keycloak-username>` is the Keycloak `username` (the realm maps the `username` claim), not the email.

## Rotate the client secret

```bash
NEW_SECRET=$(curl -sS -X POST "$KC/clients/$CID/client-secret" -H "Authorization: Bearer $TOKEN" | jq -r .value)
# write $NEW_SECRET to Vault kv/prod/proxmox-oidc OIDC_CLIENT_SECRET, then:
ssh root@172.20.20.6 'read -r S; pveum realm modify keycloak --client-key "$S"' <<<"$NEW_SECRET"
unset NEW_SECRET
```

Feed the secret over stdin as above so it never lands in shell history or `ps`.

## Gotchas

- **Keycloak down ≠ locked out.** Log in with `root@pam`.
- **Test users need required actions cleared** (`VERIFY_EMAIL`, profile fields); otherwise the flow stops at a required-action page and looks like a Proxmox failure.
- **Autocreate stays off.** The `master` realm holds unrelated users; turning it on would give every one of them a Proxmox account (with no ACL, but still a foothold).
