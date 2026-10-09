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
- State is currently local and ignored by Git. Keep it backed up securely; a fresh clone needs an import before planning. Existing production DNS records, Access policies, and tunnel/connector lifecycle are not managed by this stack.


## Management commands

Load `TF_VAR_cloudflare_api_token` from `kv/prod/cloudflare-iac` without printing it or placing it in Git, then run:

```bash
cd terraform/stacks/cloudflare/tunnel
terraform init
terraform fmt -check
terraform validate
terraform plan
terraform apply
```

On a fresh checkout without state, import the existing resources before planning:

```bash
terraform import cloudflare_zero_trust_tunnel_cloudflared_config.maurice_config e0e043685655b3d2d63201a6c84fc409/e163e2bb-e184-41aa-a96b-eb1dbdb99418
terraform import cloudflare_dns_record.tunnel_test 2a78e16b4af72edb6058ea4127aee9cd/d58d48363b686a4db0a08962d3a92dea
```

Saved plans contain the provider credential; store them outside Git with mode `0600` and remove them after use. Review each plan before applying; dashboard edits can otherwise be overwritten.


## Rollback boundary

To remove the test, delete only the `tunnel-test.levangie.dev` ingress entry and `cloudflare_dns_record.tunnel_test` resource, review the plan, then apply. Keep the existing connector running. Tunnel destruction, credential revocation, and connector replacement require separate approval.
