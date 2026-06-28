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
| `termix` | `ghcr.io/lukegus/termix:latest` | Web UI and SSH/remote-session management |
| `guacd` | `guacamole/guacd:1.6.0` | Apache Guacamole protocol proxy for RDP, VNC, and Telnet sessions |

`guacd` is intentionally a sidecar in the same pod as Termix. Termix connects to it over the pod-local loopback interface:

```yaml
ENABLE_GUACAMOLE: "true"
GUACD_HOST: localhost
GUACD_PORT: "4822"
```

There is no separate `termix-guacd` Service or Deployment. If RDP/VNC/Telnet stops working, verify the sidecar first:

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

## Deployment notes

This app is GitOps-managed. Make changes in Git under `argocd/manifests/termix/`, then verify ArgoCD and the live workload:

```bash
kubectl -n argocd get application termix
kubectl -n termix rollout status deploy/termix
kubectl -n termix get deploy,svc,pod -o wide
```
