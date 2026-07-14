# Jellyfin invite automation

`join.levangie.dev` serves the dedicated `ghcr.io/jlevangi/jellyfin-invite:sha-a4bcb50` Flask/Gunicorn app in the `jellyfin-invite` namespace. Invite state is stored in SQLite on the `jellyfin-invite-data-pvc` Longhorn PVC. Keycloak remains the identity and access source of truth.

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

- Source repo: `https://github.com/jlevangi/jellyfin-invite`
- GitOps app: `argocd/apps/prod/jellyfin-invite.yaml`
- Deployment: `argocd/manifests/jellyfin-invite/base/deployment.yaml`
- Service: `argocd/manifests/jellyfin-invite/base/service.yaml`
- Ingress: `argocd/manifests/jellyfin-invite/base/ingress.yaml`
- PVC: `argocd/manifests/jellyfin-invite/base/pvc.yaml`
- Secret source: `kv/prod/jellyfin-invite`
- Keycloak client: `n8n-invite-automation` can be reused for the first pass.
- Keycloak target group: `jellyfin-users`

Expected Vault keys at `kv/prod/jellyfin-invite`:

- `ADMIN_TOKEN`
- `KEYCLOAK_CLIENT_ID`
- `KEYCLOAK_CLIENT_SECRET`
- `KEYCLOAK_GROUP_ID`
- `GHCR_USERNAME`
- `GHCR_TOKEN`

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
kubectl kustomize argocd/manifests/jellyfin-invite/overlays/prod
KUBECONFIG=/home/pierce/.kube/config kubectl --context k3s-prod -n argocd get application jellyfin-invite
KUBECONFIG=/home/pierce/.kube/config kubectl --context k3s-prod -n jellyfin-invite rollout status deploy/jellyfin-invite
curl -sS https://join.levangie.dev/healthz
curl -sS https://join.levangie.dev/j/<code>
```

## Notes

Wizarr remains reachable at `wizarr.levangie.dev` for now, but `join.levangie.dev` routes to the standalone `jellyfin-invite` app. n8n is no longer in the invite-code path.
