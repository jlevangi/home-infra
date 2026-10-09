# Book services public exposure checklist

Current publication is documented in [Cloudflare Tunnel operations](cloudflare-tunnel.md): Terraform owns Maurice's remote ingress configuration and external-dns publishes annotated Kubernetes Ingresses. The existing LXC connector is unchanged. Do not add tunnel routes in the dashboard; Terraform will overwrite remote configuration changes.

The three book-service routes below were published manually on 2026-10-08 and remain explicit legacy routes in Terraform. Their existing DNS records are not automatically owned or withdrawn by external-dns. Moving them to annotation ownership requires a reviewed route/DNS cutover; adding or removing an annotation alone does not migrate legacy records.

All three require authentication (Shelfmark and Audiobookshelf via Keycloak OIDC, Calibre-Web via OAuth with anonymous browsing disabled). Do not expose them without that in place. New annotation-driven publication also requires a valid origin TLS certificate; the historical `noTLSVerify` settings below are not the wildcard-route standard.

## Historical tunnel ingress setup — 2026-10-08

The following routes were added through the dashboard before Terraform took ownership. Preserve this inventory as history, not instructions for new publication. Explicit rules precede wildcard rules and the final `http_status:404` catch-all.

| Hostname | Service | Origin request |
|---|---|---|
| `shelfmark.levangie.dev` | `https://k3s-prod.levangie.dev` | `noTLSVerify=true`; `httpHostHeader=shelfmark.levangie.dev`; `originServerName=shelfmark.levangie.dev` |
| `calibre.levangie.dev` | `https://k3s-prod.levangie.dev` | `noTLSVerify=true`; `httpHostHeader=calibre.levangie.dev`; `originServerName=calibre.levangie.dev` |
| `audiobooks.levangie.dev` | `https://k3s-prod.levangie.dev` | `noTLSVerify=true`; `httpHostHeader=audiobooks.levangie.dev`; `originServerName=audiobooks.levangie.dev` |

No path matchers. Type: `HTTPS`.

## Historical DNS setup — 2026-10-08

These CNAMEs were created manually in the `levangie.dev` zone. They remain separately owned legacy records, not external-dns-managed records:

| Type | Name | Target | Proxy | TTL |
|---|---|---|---|---|
| `CNAME` | `shelfmark` | `e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com` | Proxied (orange cloud) | Auto |
| `CNAME` | `calibre` | `e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com` | Proxied (orange cloud) | Auto |
| `CNAME` | `audiobooks` | `e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com` | Proxied (orange cloud) | Auto |

## Verify

Each hostname should resolve publicly (proxied Cloudflare IPs) and return
HTTP 200 with the app's login page, not a Cloudflare 502/404:

```bash
nslookup shelfmark.levangie.dev 8.8.8.8
curl -s -o /dev/null -w "%{http_code}\n" https://shelfmark.levangie.dev
curl -s -o /dev/null -w "%{http_code}\n" https://calibre.levangie.dev
curl -s -o /dev/null -w "%{http_code}\n" https://audiobooks.levangie.dev
```

## Auth prerequisite (already done, 2026-10-08)

Keycloak master realm (`auth.levangie.org`) self-registration is now disabled
(`registrationAllowed=false`) so accounts can only be created by an admin in
Keycloak itself. Existing Keycloak users get access to these apps on first OIDC
login (Shelfmark `OIDC_AUTO_PROVISION=true`, Audiobookshelf
`authOpenIDAutoRegister=true`) — no per-app account creation needed.
