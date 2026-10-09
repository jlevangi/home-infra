# Cloudflare Tunnel operations

## Current state

Production uses the remotely managed `Maurice` tunnel (`e163e2bb-e184-41aa-a96b-eb1dbdb99418`) and its active LXC connector on `172.20.20.254`. The existing connector and tunnel identity are not managed or replaced by this Terraform stack.

The planned `k3s-prod-gitops` local-tunnel migration is separate future work. This stack manages only `Maurice`'s remote ingress configuration and reviewed DNS records. Do not change connectors or existing DNS as part of a route test.

## Ownership

| Concern | Owner |
|---|---|
| Existing tunnel identity and connector | Existing Cloudflare/LXC operations |
| Remote ingress configuration (legacy routes + `*.levangie.dev` wildcard) | Terraform |
| Public DNS for annotated Ingresses | `external-dns-cloudflare` (ArgoCD app) |
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
2. Ensure the host has a valid TLS certificate on Traefik. The wildcard route verifies it (`matchSNItoHost`), and Cloudflare's universal edge certificate only covers single-level names such as `app.levangie.dev`.

`external-dns-cloudflare` watches annotated Ingresses in `levangie.dev`, `levangie.org` and `everlyera.com` and keeps a proxied CNAME to `e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com` for each host. Maurice has static wildcard rules for all three domains pointing to `https://k3s-prod.levangie.dev`, placed after the explicit legacy routes, so Traefik routes the request by Host. The DNS record is the only switch; the tunnel config does not change per app.

- **Latency**: external-dns runs every minute.
- **Removal**: change the annotation to `internal` or remove it. The record is deleted on the next run (`policy: sync`). Only records with this instance's TXT owner (`k3s-prod-cloudflare-tunnel`, prefix `_edns.`) are ever deleted, so legacy records are safe.
- **Whole-hostname publication**: a tunnel route exposes every path on a host. Do not annotate a host that also carries internal-only paths.
- **Targets**: `--force-default-targets` points every record at the tunnel, even on Ingresses that set `external-dns.alpha.kubernetes.io/target` for Technitium.
- **No Cloudflare Access**: publishing adds no Access policy. The application's own authentication is the only gate.
- **IP allowlists do not apply**: tunnel traffic reaches Traefik from the connector's LAN address, so source-IP allowlists treat public visitors as internal.
- **Wildcard caveat**: any proxied CNAME to Maurice under one of the three domains, including one added by hand in the dashboard, now reaches Traefik.

> **Note**: Static legacy routes (e.g., `hass`, `auth`) live in `local.static_ingress` in `main.tf`. Explicit routes match before the wildcard. To move one to annotation ownership, delete its route and its hand-made DNS record, then add the annotation.

Verified 2026-10-09 with a canary Ingress (`exposure-test.levangie.dev`, also carrying `external-dns.alpha.kubernetes.io/target: k3s-prod.levangie.dev`): external-dns created a proxied CNAME to the tunnel (the forced default target won) plus its owner TXT; public HTTPS returned the canary through the wildcard route with origin TLS verified. Setting the annotation to `internal` removed both records (about 3 minutes) and public HTTPS returned 530. Tunnel config and all other zone records were unchanged throughout.

Also verified `levangie.org` public canary HTTPS and DNS creation/deletion in both `levangie.org` and `everlyera.com`. Everly Era's origin certificate covers only `everlyera.com`, `www.everlyera.com` and `gallery.everlyera.com`; other names need their own certificate before HTTPS works. Deleted nine explicitly approved old `.org` CNAMEs pointing to a different tunnel, not Maurice; rollback records are saved locally at `/tmp/cloudflare-org-dns-rollback.json` (0600).

### Troubleshooting

```bash
kubectl -n cloudflare-exposure logs deploy/external-dns-cloudflare
```

The token needs DNS Edit on `levangie.dev` (it currently reuses `prod/cloudflare-iac`).

## Direct Management

Terraform manages only the tunnel configuration and the `tunnel-test` record. Retrieve the token from Vault `prod/cloudflare-iac` without echoing it. State is in R2 bucket `home-infra-terraform-state`, key `cloudflare/tunnel/terraform.tfstate`; the S3 key is the token ID and the secret is SHA-256(token).

```bash
cd terraform/stacks/cloudflare/tunnel
export TF_VAR_cloudflare_api_token="$CLOUDFLARE_API_TOKEN"
export AWS_ACCESS_KEY_ID=$(curl -fsS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" https://api.cloudflare.com/client/v4/user/tokens/verify | jq -r .result.id)
export AWS_SECRET_ACCESS_KEY=$(printf %s "$CLOUDFLARE_API_TOKEN" | sha256sum | cut -d' ' -f1)
terraform init
terraform plan
```

To remove the test, delete only the `tunnel-test.levangie.dev` ingress entry and `cloudflare_dns_record.tunnel_test` resource, review the plan, then apply. Keep the existing connector running. Tunnel destruction, credential revocation, and connector replacement require separate approval.
