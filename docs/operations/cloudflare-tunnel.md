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
| Public exposure decision | Per-Ingress `cloudflare-tunnel.levangie.dev/exposure: external` annotation (opt-in), plus the static legacy list in `main.tf` |

An Ingress without the annotation is never published.

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

The `cloudflare-exposure-reconcile` CronJob runs `terraform apply` every 15 minutes. Terraform reads live Ingresses from the cluster with a read-only ServiceAccount (`list` on namespaces and Ingresses). ArgoCD has already rendered and applied them, so the stack never re-renders Helm or Kustomize sources.

- **Whole-hostname publication**: a tunnel route exposes every path on a host. If any Ingress for a host is `external`, every Ingress sharing that host must be `external`, or the apply fails.
- **Removal**: change the annotation to `internal` or remove it. The next run deletes the DNS record and tunnel route.
- **Guards** (apply fails, nothing changes): zero Ingresses read, invalid annotation value, external host outside `levangie.dev`, annotation on a legacy static host, missing remote state.
- **Origin**: generated routes use `https://k3s-prod.levangie.dev` with Host/SNI set to the hostname and TLS verification on. The host needs a valid certificate on Traefik first.
- **No Cloudflare Access**: publishing adds no Access policy. The application's own authentication is the only gate.
- **State**: R2 bucket `home-infra-terraform-state`, key `cloudflare/tunnel/terraform.tfstate`, with lockfile locking so manual and automated applies cannot overlap.

> **Note**: Static legacy routes (e.g., `hass`, `auth`) live in `local.static_ingress` in `main.tf` and are never changed by the annotation. To move one to annotation ownership, delete it from `static_ingress` and add the annotation in the same change.

### Manual Reconciliation

If you need changes applied faster than the 15-minute schedule:

```bash
kubectl create job --from=cronjob/cloudflare-exposure-reconcile -n cloudflare-exposure manual-reconcile
kubectl logs -f job/manual-reconcile -n cloudflare-exposure
```

If a run fails, read the Job log first: the precondition message names the offending Ingress or host. Otherwise check the R2 lock and token validity. The token needs Tunnel Edit, DNS Edit, Zone Read and R2 read/edit; the R2 S3 key is the token ID and the S3 secret is SHA-256(token).

## Direct Management

Retrieve the token from Vault `prod/cloudflare-iac` without echoing it. Terraform also needs a kubeconfig whose current context is `k3s-prod`.

```bash
cd terraform/stacks/cloudflare/tunnel
export TF_VAR_cloudflare_api_token="$CLOUDFLARE_API_TOKEN"
export AWS_ACCESS_KEY_ID=$(curl -fsS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" https://api.cloudflare.com/client/v4/user/tokens/verify | jq -r .result.id)
export AWS_SECRET_ACCESS_KEY=$(printf %s "$CLOUDFLARE_API_TOKEN" | sha256sum | cut -d' ' -f1)
terraform init
terraform plan
```

To remove the test, delete only the `tunnel-test.levangie.dev` ingress entry and `cloudflare_dns_record.tunnel_test` resource, review the plan, then apply. Keep the existing connector running. Tunnel destruction, credential revocation, and connector replacement require separate approval.
