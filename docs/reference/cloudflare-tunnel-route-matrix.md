# Cloudflare Tunnel route parity matrix

Status: **authoritative API inventory complete; exposure intent review required before scaffolding**.

Every current rule is represented once. Classifications are conservative: existing public routes with a matching K3s Ingress are migration candidates; non-K3s origins are deferred; unmatched K3s-targeted routes are stale/legacy candidates requiring Pierce confirmation. No deletion intent is inferred.

| hostname | current rule index | Cloudflare zone | DNS record | origin | K8s Ingress | exposure | migration wave | test |
|---|---:|---|---|---|---|---|---:|---|
| `hass.levangie.org` | 0 | `levangie.org` | `CNAME e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com`; proxied=true; ID `5ba1e60937a5952699794c56fb228942` | `https://caddy` | none | non-K3s origin; preserve exact LAN target or defer | defer | origin reachability + owner review |
| `request.levangie.org` | 1 | `levangie.org` | `CNAME e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com`; proxied=true; ID `e242b705943985ff18c477dd9e79f40b` | `https://request.levangie.dev` | none | non-K3s origin; preserve exact LAN target or defer | defer | origin reachability + owner review |
| `photos.levangie.org` | 2 | `levangie.org` | `CNAME e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com`; proxied=true; ID `c68ff39346d8263d5917945bb100597f` | `https://k3s-prod.levangie.dev` | `immich/immich-ingress` | public and migrate | Pierce review | DNS/TLS/HTTP + app smoke |
| `guac.levangie.org` | 3 | `levangie.org` | `CNAME e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com`; proxied=true; ID `c9e51bfdc5267ae886d4ebb505f1bffe` | `http://172.20.20.26:8080` | none | non-K3s origin; preserve exact LAN target or defer | defer | origin reachability + owner review |
| `auth.levangie.org` | 4 | `levangie.org` | `CNAME e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com`; proxied=true; ID `3fa9cf183b62fb60db4fc6434cab803f` | `https://k3s-prod.levangie.dev` | `keycloak/keycloak-ingress` | public and migrate | Pierce review | DNS/TLS/HTTP + app smoke |
| `cs.levangie.org` | 5 | `levangie.org` | `CNAME e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com`; proxied=true; ID `c3bdc30c3f424139b8e61c79acdb0c49` | `https://caddy` | none | non-K3s origin; preserve exact LAN target or defer | defer | origin reachability + owner review |
| `3dprintcalc.levangie.org` | 6 | `levangie.org` | `CNAME e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com`; proxied=true; ID `249f60b746713d3dc7f73ad1b5619704` | `https://caddy` | `3dprintcalc/printcalc-ingress` | non-K3s origin; preserve exact LAN target or defer | defer | origin reachability + owner review |
| `bin.levangie.org` | 7 | `levangie.org` | `CNAME e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com`; proxied=true; ID `fa6aa708824975fb63da5ae0633fe468` | `https://k3s-prod.levangie.dev` | none | legacy/stale; remove after owner confirmation | defer | owner + live origin review |
| `lazydj.xyz` | 8 | `lazydj.xyz` | `CNAME e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com`; proxied=true; ID `323003a091391414f61df8cc536212be` | `https://caddy` | none | non-K3s origin; preserve exact LAN target or defer | defer | origin reachability + owner review |
| `memos.levangie.org` | 9 | `levangie.org` | `CNAME e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com`; proxied=true; ID `13cc9a67d416aeca7aec41dac52d7dc0` | `https://k3s-prod.levangie.dev` | `memos/memos-ingress` | public and migrate | Pierce review | DNS/TLS/HTTP + app smoke |
| `affirmation.levangie.org` | 10 | `levangie.org` | `CNAME e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com`; proxied=true; ID `4bde4f8ef0367fa3ce5887e038d88a9a` | `https://caddy` | none | non-K3s origin; preserve exact LAN target or defer | defer | origin reachability + owner review |
| `pokernight.levangie.org` | 11 | `levangie.org` | `CNAME e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com`; proxied=true; ID `6f672e588de872f050f45e7f35a0bf2b` | `https://caddy` | none | non-K3s origin; preserve exact LAN target or defer | defer | origin reachability + owner review |
| `pics.levangie.org` | 12 | `levangie.org` | `CNAME e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com`; proxied=true; ID `70fe7b5b37455c775035a8eba0fe64ad` | `http://k3s-prod.levangie.dev` | none | legacy/stale; remove after owner confirmation | defer | owner + live origin review |
| `swingspot.levangie.dev` | 13 | `levangie.dev` | `CNAME e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com`; proxied=true; ID `02ab58d0355669d136082c71dd76f1d9` | `https://caddy` | none | non-K3s origin; preserve exact LAN target or defer | defer | origin reachability + owner review |
| `cloud.levangie.org` | 14 | `levangie.org` | `CNAME e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com`; proxied=true; ID `c15f187481c70634ba84bd8883a53c34` | `https://k3s-prod.levangie.dev` | none | legacy/stale; remove after owner confirmation | defer | owner + live origin review |
| `vw.levangie.dev` | 15 | `levangie.dev` | `CNAME e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com`; proxied=true; ID `0b926c7c548ab743cc82b6d56fac2ced` | `https://k3s-prod.levangie.dev` | `vaultwarden/vaultwarden-ingress` | public and migrate | Pierce review | DNS/TLS/HTTP + app smoke |
| `dressindex.levangie.org` | 16 | `levangie.org` | `CNAME dressindex.pages.dev`; proxied=true; ID `eb904cbad63eae5cb2989663d68a39aa` | `https://caddy` | none | non-K3s origin; preserve exact LAN target or defer | defer | origin reachability + owner review |
| `ntfy.levangie.dev` | 17 | `levangie.dev` | `CNAME e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com`; proxied=true; ID `4e32d133688a037b9a8292b257743a86` | `https://k3s-prod.levangie.dev` | `ntfy/ntfy-ingress` | public and migrate | Pierce review | DNS/TLS/HTTP + app smoke |
| `paperless.levangie.dev` | 18 | `levangie.dev` | `CNAME e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com`; proxied=true; ID `0f63bbe5ed63f98cc80ce4009e9fed3b` | `https://k3s-prod.levangie.dev` | `paperless/paperless-ingress` | public and migrate | Pierce review | DNS/TLS/HTTP + app smoke |
| `request.levangie.dev` | 19 | `levangie.dev` | `CNAME e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com`; proxied=true; ID `13c0c508e0db6fc11d09165d453f697d` | `https://k3s-prod.levangie.dev` | `yams/seerr-ingress` | public and migrate | Pierce review | DNS/TLS/HTTP + app smoke |
| `bin.levangie.dev` | 20 | `levangie.dev` | `CNAME e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com`; proxied=true; ID `8b8cc38d59631365e3c50d2b10462d99` | `https://k3s-prod.levangie.dev` | `microbin/microbin-ingress` | public and migrate | Pierce review | DNS/TLS/HTTP + app smoke |
| `library.levangie.dev` | 21 | `levangie.dev` | `CNAME e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com`; proxied=true; ID `f10b4cf734a4e7879591e78ec9e432e0` | `https://k3s-prod.levangie.dev` | `bookstack/bookstack-ingress` | public and migrate | Pierce review | DNS/TLS/HTTP + app smoke |
| `vw.levangie.org` | 22 | `levangie.org` | `A 172.20.20.200`; proxied=false; ID `109dcbb203381eac97fcc888ecc1f8d4` | `https://k3s-prod.levangie.dev` | `vaultwarden/vaultwarden-ingress` | public and migrate | Pierce review | DNS/TLS/HTTP + app smoke |
| `plausible.levangie.dev` | 23 | `levangie.dev` | `CNAME e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com`; proxied=true; ID `0aa6c7d1419f63b0966fc1e24630692c` | `https://k3s-prod.levangie.dev` | `plausible/plausible-ingress` | public and migrate | Pierce review | DNS/TLS/HTTP + app smoke |
| `kayleewatkins.com` | 24 | `kayleewatkins.com` | `CNAME e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com`; proxied=true; ID `6ba12cf9e5a6dc42789be39e17a0741a` | `https://k3s-prod.levangie.dev` | `kayleewatkins/kayleewatkins-ingress` | public and migrate | Pierce review | DNS/TLS/HTTP + app smoke |
| `join.levangie.dev` | 25 | `levangie.dev` | `CNAME e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com`; proxied=true; ID `9e34692eeee3ed2a223d180357ec37f7` | `https://k3s-prod.levangie.dev` | `jellyfin-invite/jellyfin-invite` | public and migrate | Pierce review | DNS/TLS/HTTP + app smoke |
| `seerr.levangie.org` | 26 | `levangie.org` | `CNAME e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com`; proxied=true; ID `1c5a3adda4c0110ca6cc869898c0a2d8` | `https://k3s-prod.levangie.dev` | `yams/seerr-jellyfin-ingress` | public and migrate | Pierce review | DNS/TLS/HTTP + app smoke |
| `<catch-all>` | 27 | n/a | n/a | `http_status:404` | n/a | required deny fallback | n/a | unmatched URL returns 404 |

## Findings

- 27 hostname routes plus one catch-all.
- No path-specific or non-HTTP routes.
- 76 live K3s Ingress hosts exist; only current explicit tunnel routes are considered here.
- 14 routes target K3s and have a matching live Ingress.
- 10 routes use non-K3s/Caddy/LAN origins and must preserve their exact target or remain deferred.
- 3 K3s-targeted routes lack a live exact-host Ingress and are stale/legacy candidates: `bin.levangie.org`, `pics.levangie.org`, `cloud.levangie.org`.
- Migration wave remains `Pierce review` for all candidates. App criticality/auth/upload/websocket behavior is not safely derivable from route and Ingress inventory alone.

## Approval gate

Pierce must confirm exposure intent and migration wave for every hostname marked `Pierce review` or `defer`. Terraform/tunnel scaffolding is intentionally blocked until that review and an encrypted remote backend decision.
