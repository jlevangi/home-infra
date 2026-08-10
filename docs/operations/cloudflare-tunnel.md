# Cloudflare Tunnel operations

## Current and target state

Production still uses the active remotely managed connector on LXC `172.20.20.254`. Do not stop or modify it during inventory and build work.

The approved target is a new locally managed tunnel named `k3s-prod-gitops`, run by two cloudflared replicas on separate normal K3s workers. The old and new tunnels remain parallel until explicit DNS cutover approval.

## Ownership

| Concern | Owner |
|---|---|
| Tunnel and approved public DNS | Terraform |
| Connector, ordered routes, and monitoring | ArgoCD/Kustomize |
| Credentials and API token | Vault + External Secrets Operator |
| Public exposure decision | Reviewed route allowlist |

A Kubernetes Ingress does not imply public exposure. Never derive public routes from all cluster Ingress hosts.

## Authoritative current inventory

Read-only API inventory on 2026-07-21 found tunnel `Maurice` (`e163e2bb-e184-41aa-a96b-eb1dbdb99418`) healthy. The live configuration has continued to grow through reviewed additions. On 2026-08-10, `gallery.everlyera.com` was added as an explicit route to `https://k3s-prod.levangie.dev`, immediately before the final `http_status:404`, with a proxied CNAME to the Maurice tunnel. It serves the isolated Everly Era Immich deployment in `everlyera-galleries`; it does not share the personal Immich instance.

- 14 K3s-targeted routes have a matching live Ingress.
- 10 routes preserve Caddy or other LAN origins and are deferred.
- 3 additional K3s-targeted routes lack an exact live Ingress: `bin.levangie.org`, `pics.levangie.org`, and `cloud.levangie.org`. Treat these only as stale candidates pending owner confirmation.
- `cloud.levangie.dev` is an approved public FileBrowser Quantum route to `https://k3s-prod.levangie.dev`; its proxied CNAME targets the `Maurice` tunnel.
- `files.levangie.dev` is an approved public Pingvin Share X route to `https://k3s-prod.levangie.dev`; it is immediately before the catch-all and its proxied CNAME targets the `Maurice` tunnel.
- All 29 hostnames have exact public DNS records across `levangie.org`, `levangie.dev`, `lazydj.xyz`, and `kayleewatkins.com`.
- Full ordered options and DNS IDs are in `docs/reference/cloudflare-tunnel-current-routes.md`; parity decisions are in `docs/reference/cloudflare-tunnel-route-matrix.md`.

The current LXC connector remains active/enabled on cloudflared `2024.8.3`. `root-prod` remains `Synced Healthy`.

## Credential prerequisites

- `kv/prod/cloudflare-iac`: `CLOUDFLARE_API_TOKEN` exists and is active
- `kv/prod/cloudflare-tunnel`: `credentials.json` only after approved creation of the new tunnel

Never print these values or place them in Git or committed Terraform variables.

## Safe workflow

1. Export current tunnel configuration and DNS through the Cloudflare API.
2. Complete `docs/reference/cloudflare-tunnel-route-matrix.md` and compare order with the dashboard.
3. Select an encrypted, backed-up Terraform backend.
4. Review a Terraform plan that creates only the parallel tunnel; apply only after approval.
5. Store tunnel credentials in Vault without displaying them.
6. Build and validate locally managed connector configuration from the approved matrix.
7. Deploy connectors with no DNS changes and verify two healthy replicas.
8. Present the DNS plan and blast radius for explicit cutover approval.
9. Migrate one canary, then bounded waves with observation windows.
10. Stop the LXC connector only after final parity approval; retain it for the rollback window.

## Required validation

```bash
terraform fmt -check -recursive terraform/stacks/cloudflare/prod
terraform -chdir=terraform/stacks/cloudflare/prod validate
kubectl kustomize argocd/manifests/cloudflare-tunnel/overlays/prod
kubectl --context k3s-prod apply --server-side --dry-run=server -k argocd/manifests/cloudflare-tunnel/overlays/prod
cloudflared tunnel ingress validate
```

Also verify route selection for every hostname/path, two replicas on different non-GPU workers, Cloudflare connection health, metrics, and representative direct-origin Host-header requests.

## Rollback boundary

DNS rollback points an affected CNAME back to the old tunnel target. Keep the LXC connector active until all records have passed parity checks. Credential revocation, old tunnel destruction, and LXC decommission are separate destructive approvals after the rollback window.
