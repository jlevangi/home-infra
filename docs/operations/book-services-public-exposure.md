# Book services public exposure checklist

Manual Cloudflare Tunnel + DNS steps for exposing Shelfmark, Calibre-Web, and
Audiobookshelf publicly. Tunnel `Maurice` (`e163e2bb-e184-41aa-a96b-eb1dbdb99418`)
is remotely managed outside this repo; both steps below are dashboard work.

Each service already has a live Traefik Ingress (host matches the hostname below),
so no cluster-side change is needed. All three require authentication
(Shelfmark and Audiobookshelf via Keycloak OIDC, Calibre-Web via OAuth with
anonymous browsing disabled) — do not expose any of these without that in place.

## Step 1: Tunnel ingress rules

Cloudflare Zero Trust dashboard → Networks → Tunnels → `Maurice` → Public Hostname
→ Add a public hostname. Insert each **immediately before** the final
`http_status:404` catch-all; order matters.

| Hostname | Service | Origin request |
|---|---|---|
| `shelfmark.levangie.dev` | `https://k3s-prod.levangie.dev` | `noTLSVerify=true`; `httpHostHeader=shelfmark.levangie.dev`; `originServerName=shelfmark.levangie.dev` |
| `calibre.levangie.dev` | `https://k3s-prod.levangie.dev` | `noTLSVerify=true`; `httpHostHeader=calibre.levangie.dev`; `originServerName=calibre.levangie.dev` |
| `audiobooks.levangie.dev` | `https://k3s-prod.levangie.dev` | `noTLSVerify=true`; `httpHostHeader=audiobooks.levangie.dev`; `originServerName=audiobooks.levangie.dev` |

No path matchers. Type: `HTTPS`.

## Step 2: DNS CNAMEs

Cloudflare dashboard → `levangie.dev` zone → DNS → Add record, one per hostname:

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
