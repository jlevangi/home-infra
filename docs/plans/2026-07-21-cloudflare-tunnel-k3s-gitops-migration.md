# Cloudflare Tunnel K3s GitOps Migration Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Replace the remotely managed Cloudflare Tunnel connector on LXC `172.20.20.254` with a highly available, locally configured cloudflared deployment in `k3s-prod`, with routes and public DNS owned by code and secrets supplied from HashiCorp Vault.

**Architecture:** Create a new locally managed Cloudflare Tunnel and run two stateless cloudflared replicas on separate production workers. Keep ordered ingress rules in a Git-tracked ConfigMap, keep the tunnel credentials JSON and Cloudflare automation token in Vault, and manage proxied Cloudflare DNS records through a dedicated Terraform stack. Run the new and old tunnels in parallel, migrate hostnames in bounded waves, and retain the old LXC connector as rollback until validation is complete.

**Tech Stack:** Cloudflare Tunnel, Cloudflare Terraform provider, Terraform, Kustomize, ArgoCD, External Secrets Operator, HashiCorp Vault, Kubernetes Deployment/PDB/Service, Prometheus Operator, Blackbox Exporter, Gatus.

---

## 1. Current-state evidence and constraints

- Existing connector: LXC `172.20.20.254`.
- Existing tunnel mode: remotely managed token connector:
  ```text
  /usr/bin/cloudflared --no-autoupdate tunnel run --token <redacted>
  ```
- Existing cloudflared version: `2024.8.3`.
- No `/etc/cloudflared/config.yml` or local credentials file exists.
- The connector token is embedded in `/etc/systemd/system/cloudflared.service`.
- Existing routes are managed in Cloudflare Zero Trust and are not represented in Git.
- Logs prove at least 25 ordered ingress rules (`ingressRule=24` observed).
- Existing origin target is generally `https://k3s-prod.levangie.dev`, resolving internally to Traefik MetalLB VIP `172.20.20.200`.
- K3s currently has 76 unique Ingress hosts; not all should automatically become public.
- Production has three normal workers (`172.20.20.101-103`) plus a GPU worker. cloudflared should use normal workers only.
- Tailscale and WireGuard provide independent out-of-cluster recovery access.
- Existing Vault token `kv/prod/cloudflare/CLOUDFLARE_API_TOKEN` can list DNS zones but cannot list Cloudflare accounts or tunnels. It is insufficient for tunnel IaC.
- `levangie.dev`, `kayleewatkins.com`, and several application hostnames use proxied Cloudflare records. `levangie.org` apex DDNS remains a separate DNS-only A record and is out of scope for this migration.

## 2. Ownership model

| Concern | Owner | Source of truth |
|---|---|---|
| cloudflared pods, service, PDB, metrics | ArgoCD/Kustomize | `argocd/manifests/cloudflare-tunnel/**` |
| ordered tunnel ingress routes | ArgoCD ConfigMap | `argocd/manifests/cloudflare-tunnel/base/configmap.yaml` |
| tunnel credentials JSON | Vault + ESO | `kv/prod/cloudflare-tunnel` |
| Cloudflare tunnel resource | Terraform | `terraform/stacks/cloudflare/prod/` |
| proxied DNS CNAME records | Terraform | `terraform/stacks/cloudflare/prod/` |
| application hostname acceptance | App GitOps manifests | existing `argocd/manifests/<app>/**` Ingress resources |
| monitoring and alerts | ArgoCD | cloudflare-tunnel manifests + monitoring config |
| runtime patches/dashboard edits | Emergency use only | must be reconciled back into Git |

Do not auto-publish all Kubernetes Ingress hosts. Public exposure must remain an explicit allowlist in the tunnel config and Terraform DNS records.

## 3. Target architecture

```text
Cloudflare edge
  |
  +-- locally managed tunnel: k3s-prod
       |
       +-- cloudflared replica A (normal worker)
       +-- cloudflared replica B (different normal worker)
              |
              +-- http://traefik.traefik-system.svc.cluster.local:80
                    Host header preserved
                    |
                    +-- application Ingress
```

Use HTTP to the in-cluster Traefik service. The Cloudflare-to-cloudflared leg remains encrypted, and cluster-internal HTTP avoids TLS verification/SNI complexity and the MetalLB hairpin. Preserve the original request Host header so Traefik selects the correct Ingress.

Use a final catch-all rule:

```yaml
- service: http_status:404
```

## 4. Required credential changes

Create a dedicated Cloudflare automation token with only the permissions needed by Terraform:

- Account: Cloudflare Tunnel Edit
- Zone: DNS Edit
- Zone: Zone Read
- Resources:
  - Pierce's Cloudflare account
  - only zones included in the public route inventory

Store it as a new key/path, not by widening the DDNS token:

```text
kv/prod/cloudflare-iac
  CLOUDFLARE_API_TOKEN
```

The new tunnel's credentials JSON belongs at:

```text
kv/prod/cloudflare-tunnel
  credentials.json
```

Never commit the credentials JSON, connector token, account token, or Terraform variable file containing secrets.

## 5. Phase 0 — authoritative inventory and baseline

### Task 1: Export current Zero Trust routes

**Objective:** Produce the authoritative ordered route list before changing anything.

**Actions:**
1. Create the account-scoped automation token.
2. Query `/accounts/<account-id>/cfd_tunnel` to identify the current tunnel.
3. Query `/accounts/<account-id>/cfd_tunnel/<tunnel-id>/configurations`.
4. Save a redacted export under `docs/reference/cloudflare-tunnel-current-routes.md` containing hostname, path matcher, origin service, and origin request options, but no secrets.
5. Record all non-HTTP routes separately (`ssh://`, `tcp://`, `rdp://`, private-network routes).

**Verification:** Route count and order match the dashboard. The last rule is identified. Every hostname has an owner and intended exposure classification.

### Task 2: Build a route parity matrix

**Create:** `docs/reference/cloudflare-tunnel-route-matrix.md`

Columns:

```text
hostname | current rule index | Cloudflare zone | DNS record | origin | K8s Ingress | exposure | migration wave | test
```

Classify each route:
- public and migrate
- intentionally internal-only; do not publish
- legacy/stale; remove after owner confirmation
- non-K3s origin; preserve exact LAN target or defer

**Verification:** Every current tunnel route is accounted for exactly once. Every proposed public hostname exists in an application Ingress or has a documented non-K3s origin.

### Task 3: Capture baseline behavior

For each public hostname, record:
- public DNS type/target
- HTTP status
- redirect location if applicable
- TLS certificate validity
- application-specific health endpoint when available
- websocket/API smoke test where relevant

Use a script under `/tmp/hermes-verify-cloudflare-baseline.sh`; do not commit generated secrets or response bodies.

## 6. Phase 1 — Cloudflare Terraform stack

### Task 4: Create the stack

**Create:**
- `terraform/stacks/cloudflare/prod/versions.tf`
- `terraform/stacks/cloudflare/prod/providers.tf`
- `terraform/stacks/cloudflare/prod/variables.tf`
- `terraform/stacks/cloudflare/prod/tunnel.tf`
- `terraform/stacks/cloudflare/prod/dns.tf`
- `terraform/stacks/cloudflare/prod/outputs.tf`
- `terraform/stacks/cloudflare/prod/README.md`
- `terraform/stacks/cloudflare/prod/backend.tf` only after selecting an encrypted remote/state location

Pin the Cloudflare provider version. Mark token variables sensitive. Do not put the token into committed tfvars.

**State requirement:** Terraform state will contain tunnel IDs and may contain sensitive tunnel material depending on provider behavior. Use an encrypted, backed-up backend. Do not commit local state. If no approved remote backend exists, stop before apply and choose one deliberately.

### Task 5: Create a new tunnel in parallel

Create a tunnel named `k3s-prod-gitops` rather than importing/mutating the current remotely managed tunnel. A parallel tunnel gives deterministic rollback and avoids configuration-mode ambiguity.

Generate or obtain tunnel credentials and write them to Vault. Terraform outputs may expose sensitive material; suppress terminal output and write directly to Vault where possible.

**Verification:**
- Terraform plan creates one tunnel and no DNS changes yet.
- Cloudflare reports the new tunnel but no production hostname uses it.
- Credentials key exists in Vault without printing its value.

### Task 6: Declare DNS records from the approved matrix

Use explicit `cloudflare_dns_record` resources for only approved public hostnames. Point each proxied CNAME to:

```text
<new-tunnel-id>.cfargotunnel.com
```

Do not change DNS yet; prepare and review the plan. Preserve proxied flags and existing TTL behavior. Keep `levangie.org` DDNS record outside this stack unless separately approved.

## 7. Phase 2 — Kubernetes connector deployment

### Task 7: Create GitOps manifests

**Create:**
- `argocd/apps/prod/cloudflare-tunnel.yaml`
- `argocd/manifests/cloudflare-tunnel/base/namespace.yaml`
- `argocd/manifests/cloudflare-tunnel/base/external-secret.yaml`
- `argocd/manifests/cloudflare-tunnel/base/configmap.yaml`
- `argocd/manifests/cloudflare-tunnel/base/deployment.yaml`
- `argocd/manifests/cloudflare-tunnel/base/service.yaml`
- `argocd/manifests/cloudflare-tunnel/base/pdb.yaml`
- `argocd/manifests/cloudflare-tunnel/base/servicemonitor.yaml`
- `argocd/manifests/cloudflare-tunnel/base/kustomization.yaml`
- `argocd/manifests/cloudflare-tunnel/overlays/prod/kustomization.yaml`

Deployment requirements:
- 2 replicas
- pinned cloudflared image tag, not `latest`
- normal workers only; exclude GPU worker
- required pod anti-affinity or topology spread across hostname
- `PodDisruptionBudget` with `minAvailable: 1`
- no PVC
- `runAsNonRoot`, read-only root filesystem, dropped capabilities, seccomp RuntimeDefault
- small resource requests/limits based on observed use
- config checksum annotation so route edits roll pods deterministically
- graceful termination period
- metrics endpoint bound to `0.0.0.0:2000`
- credentials mounted read-only from ESO Secret
- ConfigMap mounted as a directory, not `subPath`

Command shape:

```text
cloudflared tunnel --config /etc/cloudflared/config/config.yaml run
```

### Task 8: Write locally managed ingress configuration

The ConfigMap contains:
- tunnel UUID
- credentials-file path
- metrics address
- protocol selection (start with `auto`; change only with evidence)
- ordered ingress rules copied from the approved route matrix
- final `http_status:404`

For K3s-hosted HTTP applications, target:

```text
http://traefik.traefik-system.svc.cluster.local:80
```

For any non-K3s origin, retain the exact reachable LAN service and verify pod egress before cutover.

**Validation:**
- `cloudflared tunnel ingress validate` against rendered config
- `cloudflared tunnel ingress rule <url>` for every hostname/path rule
- `kubectl kustomize` succeeds
- server-side dry-run succeeds
- no secret appears in rendered YAML

### Task 9: Deploy connectors without DNS cutover

Commit, push, sync root app, and verify child app `Synced Healthy`.

Verify:
- two Ready replicas on different normal workers
- both register tunnel connections
- metrics endpoint is scrapeable
- pods resolve and reach Traefik service DNS
- direct origin test with preserved Host reaches representative apps
- Cloudflare API reports healthy connections for the new tunnel

No production DNS changes occur in this task.

## 8. Phase 3 — monitoring and alerting

### Task 10: Add connector monitoring

Expose cloudflared metrics through a ClusterIP Service and ServiceMonitor.

Alert on actionable conditions:
- fewer than 2 ready replicas for 10 minutes: warning
- zero ready replicas for 2 minutes: critical
- no active tunnel connections: critical
- sustained origin request failures above a threshold: warning
- deployment unavailable or crash loop: warning

Do not alert on isolated client cancellations such as `context canceled`; current logs show these during browser asset requests and they are not proof of tunnel failure.

### Task 11: Add public-path synthetic checks

Use existing Gatus/Blackbox patterns for a representative set:
- one `levangie.dev` app
- `kayleewatkins.com`
- one authenticated app expecting redirect
- one websocket-heavy app if publicly exposed
- one `/ping` or API endpoint where auth bypass is intentional

Synthetic checks must traverse public Cloudflare, not resolve directly to Traefik.

## 9. Phase 4 — staged DNS cutover

### Task 12: Canary hostname

Choose a low-risk public hostname from the route matrix. Apply only its Terraform DNS change to the new tunnel.

Verify:
- public DNS points to the new tunnel target
- normal external request succeeds
- application-specific behavior succeeds
- new connector logs show the request
- old connector no longer receives that hostname
- monitoring remains green for at least 30 minutes

Rollback: reapply the old DNS CNAME target. DNS rollback does not require Kubernetes changes.

### Task 13: Migrate in bounded waves

Suggested waves:
1. low-risk stateless utilities
2. standard web applications
3. authenticated/OIDC applications
4. upload/websocket/streaming applications
5. apex/custom domains such as `kayleewatkins.com`
6. any non-HTTP or non-K3s origins

For each wave:
- review Terraform plan
- apply only approved records
- run route matrix tests
- inspect cloudflared metrics/logs
- wait through a defined observation window
- record result before next wave

Do not combine application Ingress changes and tunnel cutover in the same wave unless required for that hostname.

### Task 14: Final parity gate

Before shutting down the old connector:
- every approved hostname points to the new tunnel
- every route matrix test passes
- no current production DNS record targets the old tunnel UUID
- new tunnel has at least two healthy connectors
- ArgoCD app is `Synced Healthy`
- Prometheus and synthetic monitoring are green
- Tailscale and WireGuard recovery paths are verified

## 10. Phase 5 — LXC retirement

### Task 15: Stop, do not immediately destroy

On LXC `172.20.20.254`:

```bash
systemctl disable --now cloudflared
```

Verify all public paths again. Keep the LXC powered on but service-disabled for a 7-day rollback window.

Rollback:
1. Re-enable old connector.
2. Revert affected Terraform DNS records to old tunnel target.
3. Verify public paths.

### Task 16: Revoke and remove legacy credentials

After the rollback window:
- delete/revoke the old remotely managed tunnel connector token
- remove the token-bearing systemd unit
- remove cloudflared package/files if the LXC has no remaining purpose
- destroy the old tunnel only after DNS references are proven absent
- decommission the LXC through its owning Terraform/Ansible layer, not only Proxmox runtime

## 11. Documentation updates

Update or create:
- `docs/reference/cloudflare-tunnel-current-routes.md`
- `docs/reference/cloudflare-tunnel-route-matrix.md`
- `docs/operations/cloudflare-tunnel.md`
- `/home/pierce/obsidian/3. Homelab notes/Networking/Cloudflare Tunnel.md`
- relevant app notes for any exposure changes

Document:
- source-of-truth boundaries
- adding/removing a public hostname
- Terraform plan/apply workflow
- route validation commands
- monitoring signals
- rollback procedure
- why internal Kubernetes Ingress does not imply public exposure

## 12. Acceptance criteria

- Two cloudflared replicas run on different normal K3s workers.
- Tunnel routes are fully represented in Git and validated in order.
- Tunnel credentials and automation tokens exist only in Vault/runtime Secrets.
- Public DNS records are represented in Terraform.
- No dashboard-only production route remains undocumented.
- All migrated public hostnames pass route-specific external tests.
- Prometheus and synthetic monitoring cover connector and public-path failure.
- Old LXC connector is stopped only after parity; credentials are revoked only after rollback window.
- Independent Tailscale/WireGuard recovery remains available.

## 13. Explicit non-goals

- Do not expose all 76 Kubernetes Ingress hosts automatically.
- Do not replace the separate `levangie.org` DDNS CronJob.
- Do not move Tailscale or WireGuard into K3s.
- Do not mutate the existing remotely managed tunnel in place.
- Do not destroy the LXC during initial cutover.
- Do not store Cloudflare credentials in Git, Terraform state committed locally, or ArgoCD manifests.

## 14. First implementation blocker

Before Task 1 can execute, create the dedicated Cloudflare account-scoped automation token. The existing Vault token is active and can list DNS zones, but `/accounts` returns no resources, so it cannot inventory or manage Cloudflare Tunnel resources.

Required minimum permissions:
- Account / Cloudflare Tunnel / Edit
- Zone / DNS / Edit
- Zone / Zone / Read

Scope it to Pierce's Cloudflare account and only the zones approved in the route matrix.
