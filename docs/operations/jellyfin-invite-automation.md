# Jellyfin invite automation

`join.levangie.dev` serves a small Flask app in the `yams` namespace. Invite state is stored in SQLite on the `jellyfin-invite-data-pvc` Longhorn PVC. Keycloak remains the identity and access source of truth.

## Flow

1. Admin opens `https://join.levangie.dev/admin`.
2. Admin enters the shared admin token, note, and expiry days, then creates an invite.
3. Invitee opens `https://join.levangie.dev/j/<code>`.
4. Invitee submits email; the app validates the code in SQLite.
5. The app creates or finds the Keycloak user, grants `jellyfin-users`, sends the Keycloak setup email, and marks the code used.

Success text shown to users:

```text
Account has been created, and Jellyfin access granted. Please check your email to set a password.

You will sign in using Keycloak for:
- jellyfin.levangie.org
- request.levangie.org
```

## Components

- Deployment: `argocd/manifests/yams/base/deployment-jellyfin-invite.yaml`
- App ConfigMap: `argocd/manifests/yams/base/jellyfin-invite-app.yaml`
- Service: `argocd/manifests/yams/base/service-jellyfin-invite.yaml`
- PVC: `argocd/manifests/yams/base/pvc-jellyfin-invite.yaml`
- Secret source: `kv/prod/jellyfin-invite`
- Keycloak client: `n8n-invite-automation` can be reused for the first pass.
- Keycloak target group: `jellyfin-users`

Expected Vault keys at `kv/prod/jellyfin-invite`:

- `ADMIN_TOKEN`
- `KEYCLOAK_CLIENT_ID`
- `KEYCLOAK_CLIENT_SECRET`
- `KEYCLOAK_GROUP_ID`

## Admin API

All admin APIs require `X-Admin-Token`.

```bash
curl -sS https://join.levangie.dev/api/admin/invites \
  -H "X-Admin-Token: $ADMIN_TOKEN"

curl -sS -X POST https://join.levangie.dev/api/admin/invites \
  -H "Content-Type: application/json" \
  -H "X-Admin-Token: $ADMIN_TOKEN" \
  -d '{"note":"test","expiresDays":1}'

curl -sS -X POST https://join.levangie.dev/api/admin/invites/<code>/revoke \
  -H "X-Admin-Token: $ADMIN_TOKEN"
```

## Public API

```bash
curl -sS -X POST https://join.levangie.dev/api/activate \
  -H 'Content-Type: application/json' \
  -d '{"email":"pierce+jellyfin-invite-e2e@example.com","code":"<code>"}'
```

Invalid, expired, used, or revoked codes return HTTP 403 JSON.

## Verification

```bash
kubectl kustomize argocd/manifests/yams/overlays/prod
KUBECONFIG=/home/pierce/.kube/config kubectl --context k3s-prod -n yams rollout status deploy/jellyfin-invite
curl -sS https://join.levangie.dev/healthz
curl -sS https://join.levangie.dev/j/<code>
```

## Notes

Wizarr remains reachable at `wizarr.levangie.dev` for now, but `join.levangie.dev` routes to `jellyfin-invite`. n8n is no longer in the invite-code path.
