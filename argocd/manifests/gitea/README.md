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

Before browser access: prove the ingress access boundary and configure the
administrator. Before unique data or migration: verify healthy flash replicas on
distinct physical hosts, create a quiesced off-cluster backup including database,
repositories, `config/app.ini` and `config/secret_key`, and demonstrate isolated
recovery. Longhorn recurring backup labels alone do not prove consistent recovery.
Never regenerate encryption secrets when restoring an existing database.
