# DNS Automation with ExternalDNS

## Overview

DNS record management for application Ingresses is automated using [ExternalDNS](https://github.com/kubernetes-sigs/external-dns) with a [Technitium webhook provider](https://github.com/roosmaa/external-dns-technitium-webhook). When ArgoCD creates, updates, or removes an Ingress, ExternalDNS automatically reconciles the corresponding DNS records in Technitium.

## Architecture

```
Ingress (app.stage.levangie.dev)
    |
    v
ExternalDNS (watches Ingress resources)
    |
    v
Technitium Webhook Sidecar (translates to Technitium API calls)
    |
    v
Technitium DNS Server (172.20.20.4)
```

ExternalDNS runs as an ArgoCD-managed Helm release in each cluster. The deployment consists of two containers:
- **external-dns**: Watches Kubernetes Ingress resources and determines desired DNS state
- **webhook**: Sidecar that translates ExternalDNS API calls into Technitium DNS API requests

## Per-Environment Configuration

| Setting | Prod | Stage | Test |
|---------|------|-------|------|
| Domain filter | `levangie.dev` | `stage.levangie.dev` | `test.levangie.dev` |
| TXT owner ID | `k3s-prod` | `k3s-stage` | `k3s-test` |
| CNAME target | `k3s-prod.levangie.dev` | `k3s-stage.levangie.dev` | `k3s-test.levangie.dev` |
| Zone | `levangie.dev` | `levangie.dev` | `levangie.dev` |
| ArgoCD app | `argocd/apps/{env}/external-dns.yaml` | | |

## How It Works

### Automatic Record Creation

When an Ingress is created with the `external-dns.alpha.kubernetes.io/target` annotation, ExternalDNS creates a CNAME record pointing to the cluster's Traefik load balancer hostname.

Example: An Ingress with host `bin.stage.levangie.dev` and target annotation `k3s-stage.levangie.dev` creates:
```
bin.stage.levangie.dev  CNAME  k3s-stage.levangie.dev
```

### Required Ingress Annotations

Add this annotation to each Ingress (via Kustomize overlay patches for env-specific values):
```yaml
annotations:
  external-dns.alpha.kubernetes.io/target: k3s-<env>.levangie.dev
```

The `~1` escape is used in JSON Patch paths for the `/` in the annotation key:
```yaml
patches:
  - target:
      kind: Ingress
      name: myapp-ingress
    patch: |
      - op: add
        path: /metadata/annotations/external-dns.alpha.kubernetes.io~1target
        value: "k3s-stage.levangie.dev"
```

### TXT Ownership Records

ExternalDNS creates TXT records prefixed with `_edns.` to track ownership. For example:
```
_edns.bin.stage.levangie.dev  TXT  "heritage=external-dns,external-dns/owner=k3s-stage..."
```

These are normal and should not be deleted manually.

## Credential Management

### Technitium Service Account

ExternalDNS authenticates to Technitium using a dedicated `external-dns` service account (member of "DNS Administrators" group). This account does not have 2FA enabled, as the webhook does not support it.

### Kubernetes Secret

Credentials are stored in a Kubernetes secret in the `external-dns` namespace:
```
technitium-webhook-credentials:
  TECHNITIUM_URL: http://172.20.20.4:5380
  TECHNITIUM_USERNAME: external-dns
  TECHNITIUM_PASSWORD: <password>
```

This secret is created by Ansible during cluster deployment (`ansible/roles/k3s/tasks/argocd.yml`). The password is stored in `ansible/group_vars/k3s_cluster_vault.yml` as `vault_technitium_password`.

## What Ansible Still Manages

Ansible retains DNS management for platform bootstrap records that must exist before ExternalDNS is deployed:
- `k3s-<env>.levangie.dev` A record (cluster Traefik LB IP)
- `argocd.<env-domain>` CNAME (ArgoCD dashboard)
- `longhorn.<env-domain>` CNAME (Longhorn dashboard)
- `traefik.<env-domain>` CNAME (Traefik dashboard)

These are managed via `ansible/roles/k3s/tasks/shared/dns_management.yml` using the Technitium API token.

## Special Cases

### Factorio

Factorio uses a hostPort service (not an Ingress) and needs an A record pointing to a specific node IP. It retains a legacy PostSync hook Job (`argocd/manifests/factorio/base/dns-hook.yaml`) and a per-namespace `technitium-api-credentials` secret.

### Helm-Based Apps

For apps deployed via Helm charts (gatus, vault, kube-prometheus-stack), the external-dns annotation is added directly in the inline `helm.values` block of the ArgoCD Application manifest.

## Adding DNS for a New Application

1. Create an Ingress in your app's base manifests with the hostname
2. Add the `external-dns.alpha.kubernetes.io/target` annotation in each environment overlay
3. ExternalDNS will automatically create the DNS record on next sync interval (1 minute)

No secrets, hook Jobs, or Ansible changes are required.

## Troubleshooting

### Check ExternalDNS logs
```bash
kubectl logs -n external-dns -l app.kubernetes.io/name=external-dns -c external-dns
kubectl logs -n external-dns -l app.kubernetes.io/name=external-dns -c webhook
```

### Verify the secret exists
```bash
kubectl get secret technitium-webhook-credentials -n external-dns
```

### Check if ExternalDNS sees the Ingress
Look for "Endpoints generated from ingress" in debug logs. If the Ingress hostname doesn't appear, check that it matches the domain filter for the environment.

### Record not being created (owner mismatch)
If logs show "owner id does not match", the record was created outside of ExternalDNS (by a legacy hook or Ansible). ExternalDNS will not overwrite it. Delete the existing record manually in Technitium, and ExternalDNS will recreate it with proper ownership.

### Webhook authentication failure
Check webhook logs for "2fa-required" or login errors. The `external-dns` Technitium user must not have 2FA enabled.
