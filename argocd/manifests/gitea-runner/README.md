# Gitea runner pilot

Disposable native Kubernetes runner for `hermes/runner-pilot` only. Gitea Runner
4.1 creates one restricted, unprivileged job pod per workflow job in this
namespace. No Docker socket, host path, privileged mode, cache server or
deployment credential is mounted. Job pods do not receive Kubernetes API tokens.

The registration token is repository-scoped and stored at Vault
`kv/prod/gitea-runner`. GitHub remains authoritative.

Egress is limited to DNS, Gitea, Traefik HTTPS and the K3s API endpoints. External
`uses:` actions and package downloads are therefore expected to fail.

Verify:

```bash
kubectl kustomize argocd/manifests/gitea-runner/overlays/prod
kubectl -n gitea-runner get pods,networkpolicy,resourcequota
```
