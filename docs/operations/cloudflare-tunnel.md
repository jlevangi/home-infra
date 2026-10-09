# Cloudflare Tunnel operations

## Current state

Production uses the remotely managed `Maurice` tunnel (`e163e2bb-e184-41aa-a96b-eb1dbdb99418`) and its active LXC connector on `172.20.20.254`. The existing connector and tunnel identity are not managed or replaced by this Terraform stack.

The planned `k3s-prod-gitops` local-tunnel migration is separate future work. This stack manages only `Maurice`'s remote ingress configuration and reviewed DNS records. Do not change connectors or existing DNS as part of a route test.

## Ownership

| Concern | Owner |
|---|---|
| Existing tunnel identity and connector | Existing Cloudflare/LXC operations |
| Remote ingress configuration and approved DNS | Terraform |
| API token | Vault + External Secrets Operator |
| Public exposure decision | Reviewed route allowlist |

A Kubernetes Ingress does not imply public exposure. Never derive public routes from all cluster Ingress hosts.

## Current inventory

The live `Maurice` tunnel is remotely managed. Terraform references its fixed ID and manages the ordered ingress config, preserving current service targets and origin settings. Review the Cloudflare API configuration and Terraform plan before changes; do not suppress differences with `ignore_changes`.

`tunnel-test.levangie.dev` uses Cloudflare's `hello_world` built-in service and a proxied CNAME to the existing tunnel. It must precede the final `http_status:404` catch-all.
- The IaC token comes from Vault key `prod/cloudflare-iac`, property `CLOUDFLARE_API_TOKEN`, through the `vault-kv` ClusterSecretStore. Do not use the separate cert-manager token.
- This stack pins `cloudflare/cloudflare` v5.27.0. Provider v5 uses `cloudflare_dns_record` and an ingress list of object attributes, not `cloudflare_record` or `ingress_rule` blocks.
- Applied on 2026-10-09: one remote configuration update and one proxied DNS record creation; no resources destroyed. All 42 existing hostname routes, origin values, catch-all, and disabled WARP routing were preserved. Empty origin objects were normalized to absent objects.
- Verification: public DNS resolved through 1.1.1.1 and 8.8.8.8; HTTPS returned the built-in “Congrats! You created a tunnel!” page. The local resolver initially cached NXDOMAIN, so the HTTPS check used a public DNS address with the original hostname and TLS verification. Maurice remained healthy and the post-apply Terraform plan reported no changes.
- The incompatible v4 state binding was removed state-only before importing the existing config using the v5 provider. No remote tunnel was deleted or recreated.


## Automatic Exposure Routing

To expose a Kubernetes application publicly:

1. Add the annotation to its Traefik Ingress:
   ```yaml
   metadata:
     annotations:
       cloudflare-tunnel.levangie.dev/exposure: external
   ```
2. Ensure the host has a valid TLS certificate (Traefik requires it; the tunnel verifies it via `origin_server_name` matching the host).

A CronJob (`cloudflare-exposure-reconcile`) runs every 15 minutes, rendering enabled prod applications, discovering this annotation, and updating Cloudflare via Terraform using the R2 state backend.

- **Hostnames must be exact**: No path-based isolation; marking one path `external` publishes the whole hostname.
- **Removal**: Change the annotation to `internal` (or remove it entirely) and the 15-minute reconciliation will delete the DNS record and tunnel route.
- **State locking**: Uses Cloudflare R2 (`home-infra-terraform-state`) to prevent concurrent manual and automated applies.

> **Note**: Static legacy routes (e.g., `hass`, `auth`) are explicitly owned in `terraform/stacks/cloudflare/tunnel/main.tf` and are not automatically deleted. New generated routes cannot conflict with them.

### Manual Reconciliation

If you need changes applied faster than the 15-minute schedule:

```bash
kubectl create job --from=cronjob/cloudflare-exposure-reconcile -n cloudflare-exposure manual-reconcile
kubectl logs -f job/manual-reconcile -n cloudflare-exposure
```

If the tunnel is stuck or the CronJob fails, check R2 backend lock state and API token validity (requires Tunnel Edit, DNS Edit, Zone Read, and Worker R2 read/edit permissions). S3 access keys are derived from the same token.

## Direct Management

To run Terraform manually, retrieve the token from Vault `prod/cloudflare-iac`. The R2 backend handles state.

```bash
export CLOUDFLARE_API_TOKEN="..."
cd terraform/stacks/cloudflare/tunnel

# Derive AWS credentials for R2 lockfile from the Cloudflare token:
export AWS_ACCESS_KEY_ID=$(curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" https://api.cloudflare.com/client/v4/user/tokens/verify | jq -r .result.id)
export AWS_SECRET_ACCESS_KEY=$(echo -n "$CLOUDFLARE_API_TOKEN" | sha256sum | awk '{print $1}')
export TF_VAR_cloudflare_api_token=$CLOUDFLARE_API_TOKEN

terraform init
terraform plan
```

To remove the test, delete only the `tunnel-test.levangie.dev` ingress entry and `cloudflare_dns_record.tunnel_test` resource, review the plan, then apply. Keep the existing connector running. Tunnel destruction, credential revocation, and connector replacement require separate approval.
