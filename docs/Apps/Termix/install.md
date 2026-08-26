# Termix

Termix is deployed to the production K3s cluster via ArgoCD.

## Source of truth

- Application: `argocd/apps/prod/termix.yaml`
- Manifests: `argocd/manifests/termix/`
- Namespace: `termix`
- Public host: `termix.levangie.dev`

## Runtime layout

The `termix` Deployment runs a single pod with two containers:

| Container | Image | Purpose |
| --- | --- | --- |
| `termix` | `ghcr.io/lukegus/termix:2.7.1` | Web UI and SSH/remote-session management |
| `guacd` | `guacamole/guacd:1.6.0` | Apache Guacamole protocol proxy for RDP, VNC, and Telnet sessions |

`guacd` is intentionally a sidecar in the same pod as Termix. The deployment supports both connection paths:

```yaml
ENABLE_GUACAMOLE: "true"
GUACD_HOST: localhost
GUACD_PORT: "4822"
```

Termix admin settings may also point at `guacd:4822`. A small ClusterIP Service named `guacd` selects the `termix` pod and forwards port `4822` to the sidecar so that admin/UI configuration works without a separate guacd Deployment.

There is no separate `termix-guacd` Deployment. If RDP/VNC/Telnet stops working, verify the sidecar first:

```bash
kubectl -n termix get pod -l app=termix
kubectl -n termix logs deploy/termix -c guacd --tail=50
kubectl -n termix get deploy termix -o jsonpath='{range .spec.template.spec.containers[*]}{.name}:{.image}{"\n"}{end}'
```

Expected `guacd` startup log:

```text
guacd[1]: INFO: Guacamole proxy daemon (guacd) version 1.6.0 started
guacd[1]: INFO: Listening on host 0.0.0.0, port 4822
```

## Storage

Termix uses a Longhorn-backed `ReadWriteOnce` PVC:

- PVC: `termix-data-pvc`
- Mount path: `/app/data`
- StorageClass: `longhorn-redundant`
- Size: `2Gi`

## Keycloak SSO

Termix uses native OIDC against the Keycloak `master` realm.

- Client ID: `termix`
- Callback: `https://termix.levangie.dev/users/oidc/callback`
- Client secret: Vault `kv/prod/termix` → `ExternalSecret/termix-secrets`
- Allowed identity: `pierce@levangie.org`
- Admin mapping: Keycloak group `termix-admins` → Termix built-in `admin` role
- Username display claim: `preferred_username`
- Requested scopes: `openid email profile` (`groups` is emitted by a dedicated Keycloak client mapper)

The Keycloak user `pierce` is a member of `termix-admins`. Its OIDC subject is linked to the retained Termix account named `Pierce`, preserving that account's hosts, credentials, history, and recordings. Termix synchronizes administrator status from the group on every login. Password login remains enabled as recovery; do not enable silent/default OIDC login until the normal login path has been proven stable.

If OIDC creates a duplicate account, do not move only the visible host rows: Termix user-owned data spans many tables and the database file is encrypted. Stop Termix, back up `/app/data/db.sqlite.encrypted`, use the application database modules to transfer the duplicate account's OIDC fields to the retained account, then delete the empty duplicate and save the in-memory database.

To revoke Pierce's Termix admin access without disabling SSO, remove `pierce` from the Keycloak `termix-admins` group. Termix applies the downgrade on the next login.

## Deployment notes

This app is GitOps-managed. Make changes in Git under `argocd/manifests/termix/`, then verify ArgoCD and the live workload:

```bash
kubectl -n argocd get application termix
kubectl -n termix rollout status deploy/termix
kubectl -n termix get deploy,svc,pod -o wide
```
