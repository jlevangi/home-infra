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

## Credential prerequisites

- `kv/prod/cloudflare-iac`: `CLOUDFLARE_API_TOKEN`
- `kv/prod/cloudflare-tunnel`: `credentials.json` after creation of the new tunnel

The automation token requires Account Cloudflare Tunnel Edit, Zone DNS Edit, and Zone Zone Read for only the account and zones in scope. Never print these values or place them in Git or committed Terraform variables.

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
