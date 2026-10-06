# Gitea pilot

GitHub remains authoritative. This additive production pilot has one rootless
Gitea replica, SQLite and repositories on a 10Gi `longhorn-flash` PVC.

Standard Traefik HTTPS ingress serves `https://git.levangie.dev` with automatic
internal Technitium DNS. No public DNS or tunnel route is configured. SSH, signup,
installer and runners remain disabled. Operator checks can also use port-forwarding:

```bash
python3 argocd/manifests/gitea/verify.py
kubectl --context k3s-prod -n gitea port-forward svc/gitea 3000:3000
curl http://127.0.0.1:3000/api/healthz
```

Bootstrap an administrator with the supported Gitea CLI and persist the human
login only in Vaultwarden's `Hermes Agent` collection. Never print passwords in
agent output, reopen registration or use the web installer. Do not accept unique
project data yet.

## Native Keycloak login

The `master` realm confidential client `gitea` has only the callback
`https://git.levangie.dev/user/oauth2/Keycloak/callback`. Its multivalued `groups`
claim emits scoped realm roles. Exact role `Gitea-admins` includes `Gitea-users`;
Pierce has `Gitea-admins`. The Gitea source requires `groups=Gitea-users` and maps
`Gitea-admins` to local administration. No shared realm flows or policies change.

Vault `kv/prod/gitea` holds machine key `OIDC_CLIENT_SECRET`; ESO projects it to
`gitea-secrets`. Startup runs image setup and supported `gitea migrate`, then
adds or updates the single `Keycloak` source through `gitea admin auth`. Source
settings live in the PVC database, not SQLite edits. Rotate the client secret in
Keycloak and Vault together, refresh ESO, then recreate the pod to reconcile it.
Never print the secret. Keycloak client/role state is API-owned, not Git-owned.

Manual signup stays disabled; `[oauth2_client] ENABLE_AUTO_REGISTRATION=true`
allows authorized OIDC provisioning separately in v28. Automatic linking to
local accounts is disabled; keep the recovery account separate. Real browser
login must verify Pierce's mapped Gitea admin status and a role-less user's denial;
source creation and discovery alone do not prove those outcomes.

Before browser access: prove the ingress access boundary and configure the
administrator. Before unique data or migration: verify healthy flash replicas on
distinct physical hosts, create a quiesced off-cluster backup including database,
repositories, `config/app.ini` and `config/secret_key`, and demonstrate isolated
recovery. Longhorn recurring backup labels alone do not prove consistent recovery.
Never regenerate encryption secrets when restoring an existing database.
