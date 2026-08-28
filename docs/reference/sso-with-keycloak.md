# SSO with Keycloak

How we wire apps in this cluster to log in via Keycloak (`https://auth.levangie.org`, `master` realm).

## Overview

- One realm for everything: `master`. No federation; users are local Keycloak accounts.
- One OIDC client per app, named after the app (`bookstack`, `immich`, `grafana`, ...).
- Role-gated where the app supports it: realm roles `<app>-admin`, `<app>-editor`, `<app>-viewer` (or just `<app>-admin` / `<app>-user`) flow into the access/ID token as a `groups` claim, and the app maps that claim onto its own role model.
- Client secrets live in Vault at `kv/prod/<app>` under key `OIDC_CLIENT_SECRET`, synced into each namespace by [External Secrets](./vault-and-eso.md).

## Add a new app — Keycloak side

Easiest is the admin REST API. Get a token (admin password lives in Vault `kv/prod/keycloak.KEYCLOAK_ADMIN_PASSWORD`):

```bash
TOKEN=$(curl -sS -X POST https://auth.levangie.org/realms/master/protocol/openid-connect/token \
  -d grant_type=password -d client_id=admin-cli -d username=admin \
  --data-urlencode "password=$KC_ADMIN_PASS" | jq -r .access_token)
KC=https://auth.levangie.org/admin/realms/master
```

Create the client. Wildcard redirect URIs are fine — Keycloak validates per host:

```bash
curl -sS -X POST "$KC/clients" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{
  "clientId":"myapp",
  "enabled":true,
  "protocol":"openid-connect",
  "publicClient":false,
  "standardFlowEnabled":true,
  "directAccessGrantsEnabled":false,
  "clientAuthenticatorType":"client-secret",
  "redirectUris":["https://myapp.levangie.dev/*"],
  "webOrigins":["https://myapp.levangie.dev"],
  "baseUrl":"https://myapp.levangie.dev",
  "attributes":{"post.logout.redirect.uris":"https://myapp.levangie.dev/*"}
}'
```

Add the realm-roles → `groups` claim mapper on the client. Without this, the app sees no role info:

```bash
CID=$(curl -sS "$KC/clients?clientId=myapp" -H "Authorization: Bearer $TOKEN" | jq -r '.[0].id')
curl -sS -X POST "$KC/clients/$CID/protocol-mappers/models" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{
    "name":"realm roles to groups","protocol":"openid-connect",
    "protocolMapper":"oidc-usermodel-realm-role-mapper",
    "config":{"claim.name":"groups","jsonType.label":"String",
      "userinfo.token.claim":"true","id.token.claim":"true","access.token.claim":"true",
      "multivalued":"true","usermodel.realmRoleMapping.rolePrefix":""}
  }'
```

If the app explicitly requests a `groups` scope (Grafana, MeshCentral, LibreChat, ArgoCD all do), also attach the shared `groups` client scope so Keycloak doesn't 400 the auth request:

```bash
GSCOPE=$(curl -sS "$KC/client-scopes" -H "Authorization: Bearer $TOKEN" | jq -r '.[]|select(.name=="groups")|.id')
curl -sS -X PUT "$KC/clients/$CID/default-client-scopes/$GSCOPE" -H "Authorization: Bearer $TOKEN"
```

Create the realm roles and assign them to users:

```bash
for r in myapp-admin myapp-user; do
  curl -sS -X POST "$KC/roles" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d "{\"name\":\"$r\",\"description\":\"Grants $r access\"}"
done
# assign via the admin UI: Users → <user> → Role mapping → Assign role
```

Grab the client secret for Vault:

```bash
curl -sS "$KC/clients/$CID/client-secret" -H "Authorization: Bearer $TOKEN" | jq -r .value
```

## Add a new app — cluster side

### 1. Stash the secret in Vault

```bash
kubectl -n vault-raft exec -it vault-raft-0 -- env VAULT_TOKEN=<token> \
  vault kv put kv/prod/myapp OIDC_CLIENT_SECRET='<value-from-above>'
```

If `kv/prod/myapp` already exists, use `vault kv patch` instead to preserve other keys.

### 2. Add an ExternalSecret (if the app doesn't already have one)

Same shape as the other apps — see `argocd/manifests/pocketid/base/external-secret.yaml` for the canonical example. `dataFrom.extract.key: prod/myapp` brings every key into the resulting K8s secret.

### 3. Wire the env vars

Non-secret OIDC config goes in the app's ConfigMap (issuer URL, client ID, scopes, endpoint URLs). The client secret flows in via `valueFrom.secretKeyRef`. See:

- `argocd/manifests/vaultwarden/` — vendor-prefixed env vars (`SSO_*`)
- `argocd/manifests/linkding/` — django-allauth style (`OIDC_OP_*` endpoint URLs)
- `argocd/manifests/paperless/base/deployment-app.yaml` — JSON-in-env-var pattern with `$(SECRET)` substitution from a sibling env entry, keeps the secret out of the ConfigMap
- `argocd/manifests/bookstack/` — group-claim → role gating wired up end-to-end

### 4. Wire role gating (optional but recommended)

The app needs to read the `groups` claim and map names to its own roles. The exact pattern differs:

- **Bookstack:** `OIDC_USER_TO_GROUPS=true` + set each role's `external_auth_id` in the DB to the Keycloak realm role name
- **Grafana:** `role_attribute_path` JMESPath in `grafana.ini` (see below for the GrafanaAdmin gotcha)
- **ArgoCD:** `argocd-rbac-cm` policy.csv with `g, <keycloak-role>, role:<argocd-role>` plus `scopes: '[groups]'`
- **MeshCentral:** `domains.<X>.authStrategies.oidc.groups.{required,siteadmin}` in `config.json`
- **Most others:** no group-based gating; everyone with a Keycloak account gets the default role and you elevate them in-app.

## Patterns we settled on

| Concern | Choice | Why |
|---|---|---|
| Realm | One (`master`) | Personal scale; federation isn't worth the moving parts |
| Client per app | Always confidential, except CLI clients (PKCE public) | Avoids leaking client_id-only flows to a browser |
| Redirect URIs | Wildcard `https://<host>/*` | Apps disagree on callback paths; wildcard saves churn |
| Client secret in Vault | `kv/prod/<app>.OIDC_CLIENT_SECRET` | Matches the existing ESO convention |
| Role naming | `<app>-admin` / `<app>-user` (or admin/editor/viewer) | App-prefixed so realm-wide assignment makes sense |
| Token claim for roles | `groups` (multivalued string) | Matches Bookstack/Grafana/MeshCentral defaults; nothing else competes for the name |

### Immich role-claim exception

Immich expects a scalar role claim whose value is `admin` or `user`. The dedicated Everly Era gallery therefore uses a client role named `admin` and a client-role mapper that emits `immich_role=admin`; it does not use the shared multivalued `groups` claim for authorization. The existing realm role `everlyera-admin` remains the human-facing source of access, and its current members are assigned the gallery client role.

Because the shared `master` realm contains unrelated users, `gallery.everlyera.com` has Immich auto-registration disabled. Administrators must pre-create a matching Immich account before granting Keycloak access. Keep password login enabled as break-glass and store generated local passwords with the OIDC client secret at `kv/prod/everlyera-gallery-oidc`.

## Session policy

The `master` realm uses these interactive SSO limits:

| Session type | Idle timeout | Maximum lifespan |
|---|---:|---:|
| Normal | 7 days | 30 days |
| Remember Me | 30 days | 90 days |

`Remember Me` is enabled. The access-token lifespan remains 60 seconds; OIDC
clients should refresh access tokens rather than treating that short token
lifetime as an interactive logout. These settings are realm-owned in Keycloak's
database and currently require an admin API or Realm Settings change rather
than an ArgoCD manifest update.

## Login theme

The CSS-first `levangie` login theme lives under
`argocd/manifests/keycloak/base/theme/login/`. Kustomize packages those files in
a hashed ConfigMap and the Keycloak Deployment mounts it read-only at
`/opt/keycloak/themes/levangie`; `scripts/validate-keycloak-theme.py` enforces
the theme contract. The vendored logo is an optimized copy of
`jlevangi/levangie.dev:static/levangie-dev.png`. The original source SHA-256 is
`d2c969f98d974403887db1ad3938ce26b067b2a84ced2b960c9c9f09bbd1823b`;
the optimized vendored PNG SHA-256 is
`2566115dc5eafef6f811d3e823fba58f2939d24d3220d88f1a9c7d0cbb5c2907`.

Keep the theme inheriting `keycloak.v2` and CSS-only: do not add FreeMarker
`.ftl` overrides unless a future requirement justifies the upgrade burden.
After the mounted files have been deployed and verified, activate it in Realm
Settings → Themes by selecting `levangie` as the Login theme. Roll back without
a deployment by selecting `keycloak.v2` (or the blank/default login theme).
Theme selection remains realm-owned and is not performed by these manifests.

## Gotchas we hit

- **Custom-scheme redirect URIs crash Keycloak 22.** A mobile redirect like `app.immich:/` (or `app.immich:///oauth-callback`) blows up Keycloak's URI builder with `empty host name`, and the whole login fails — even for unrelated web flows on the same client. Don't register them on 22.x; revisit when we upgrade to 23+.
- **`groups` scope must be created and attached** to clients that ask for it (`requestedScopes: [..., groups]`). Without it Keycloak returns `invalid_scope` and the OIDC handshake never completes. We have a shared `groups` client scope with the same realm-roles mapper.
- **Grafana's `role_attribute_path` needs `GrafanaAdmin`, not `Admin`.** With `allow_assign_grafana_admin: true`, returning `Admin` sets only the org role and clears the server-admin flag. If the user being demoted was the last server admin, Grafana errors with `cannot remove last grafana admin` and rejects the login entirely.
- **ArgoCD only consults Secrets labeled `app.kubernetes.io/part-of: argocd`** when resolving `$<name>:<key>` references in `argocd-cm`. ESO doesn't add that label by default — set it via `spec.target.template.metadata.labels` on the ExternalSecret. Symptom: ArgoCD logs `key does not exist in secret` and Keycloak returns `invalid_client_credentials`.
- **Empty profile fields disable Keycloak's password grant.** If `admin@local` has no `email`/`first_name`/`last_name`, the token endpoint returns `Account is not fully set up`. Set stub values before automating via the API.
- **`admin-cli`'s default `full_scope_allowed: false`** strips the `admin` realm role from tokens, so admin REST calls 401. Flip it to `true` once (DB or admin UI) to use password grant for automation.
- **Keycloak caches client data.** Direct DB writes to client/redirect tables don't invalidate the cache — restart the Keycloak deployment after any out-of-band edit.
- **Bitnami's MongoDB subchart uses `RollingUpdate`** with a ReadWriteOnce PVC, so a rollout-restart stalls forever in Multi-Attach. Set `mongodb.updateStrategy.type: Recreate` in the chart values.

## Linking an existing local account to OIDC

Most apps don't auto-link when a Keycloak user has the same email as an existing local user — they either create a duplicate or refuse. The DB patches we've used:

| App | Table / location | Field to set |
|---|---|---|
| Immich | `"user"` table in `immich` Postgres | `oauthId = ''` (then OIDC login attaches by email) |
| Bookstack | `users` table in `bookstack` MariaDB | `external_auth_id = '<keycloak-sub>'` |
| LibreChat | `users` collection in `LibreChat` MongoDB | `provider = 'openid'`, `openidId = '<keycloak-sub>'` |
| Grafana | `user_auth` row + `user` table in `grafana.db` SQLite | Move `user_auth.user_id` to the local user; delete the auto-created OIDC user |
| MeshCentral | `meshcentral.db` (NeDB) | Add the OIDC user `_id` to each mesh's `links` map, and add the mesh ids to the user's `links` |

For all of these: snapshot the DB or volume first (Longhorn or `kubectl cp`), then restart the app pod after the edit so caches drop.

## See also

- [Vault and ESO](./vault-and-eso.md) — secret storage and sync
- `argocd/manifests/bookstack/` — fully-worked role-gated example
- `ansible/roles/cluster_platform/templates/argocd-values.yaml.j2` — durable ArgoCD OIDC config
