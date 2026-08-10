# Cloudflare Tunnel current routes

Inventory captured: **2026-07-21** via read-only Cloudflare API.

Update **2026-08-10**: the live tunnel contained 32 rules before this change, including newer routes not represented in the July table. `gallery.everlyera.com` was added at index 31, immediately before the catch-all, bringing the live total to 33. Its service is `https://k3s-prod.levangie.dev` with `noTLSVerify=true`, `httpHostHeader=gallery.everlyera.com`, and `originServerName=gallery.everlyera.com`. Cloudflare DNS has one proxied CNAME to the Maurice tunnel. Public verification returned `HTTP/2 200`, Immich HTML, and a valid Google Trust Services certificate for `everlyera.com`.

- Account ID: `e0e043685655b3d2d63201a6c84fc409`
- Tunnel: `Maurice` (`e163e2bb-e184-41aa-a96b-eb1dbdb99418`), remotely managed
- Ordered rules: **30 total**: 29 hostname rules and one final catch-all
- Path matchers: **none**
- Non-HTTP services: **none**

## Exact ordered ingress

| index | hostname | path | service | originRequest |
|---:|---|---|---|---|
| 0 | `hass.levangie.org` | `none` | `https://caddy` | `httpHostHeader=hass.levangie.org`; `originServerName=hass.levangie.org` |
| 1 | `request.levangie.org` | `none` | `https://request.levangie.dev` | `noTLSVerify=true`; `httpHostHeader=request.levangie.org`; `originServerName=request.levangie.org` |
| 2 | `photos.levangie.org` | `none` | `https://k3s-prod.levangie.dev` | `noTLSVerify=true`; `httpHostHeader=`; `originServerName=` |
| 3 | `guac.levangie.org` | `none` | `http://172.20.20.26:8080` | none |
| 4 | `auth.levangie.org` | `none` | `https://k3s-prod.levangie.dev` | `noTLSVerify=true`; `httpHostHeader=auth.levangie.org`; `originServerName=auth.levangie.org` |
| 5 | `cs.levangie.org` | `none` | `https://caddy` | `noTLSVerify=true`; `httpHostHeader=cs.levangie.org`; `originServerName=cs.levangie.org` |
| 6 | `3dprintcalc.levangie.org` | `none` | `https://caddy` | `noTLSVerify=true`; `httpHostHeader=3dprintcalc.levangie.org`; `originServerName=3dprintcalc.levangie.org` |
| 7 | `bin.levangie.org` | `none` | `https://k3s-prod.levangie.dev` | `noTLSVerify=true`; `httpHostHeader=bin.levangie.org`; `originServerName=bin.levangie.org` |
| 8 | `lazydj.xyz` | `none` | `https://caddy` | `originServerName=lazydj.xyz` |
| 9 | `memos.levangie.org` | `none` | `https://k3s-prod.levangie.dev` | `noTLSVerify=true`; `httpHostHeader=memos.levangie.org`; `originServerName=memos.levangie.org` |
| 10 | `affirmation.levangie.org` | `none` | `https://caddy` | `noTLSVerify=true`; `httpHostHeader=affirmation.levangie.org`; `originServerName=affirmation.levangie.org` |
| 11 | `pokernight.levangie.org` | `none` | `https://caddy` | `noTLSVerify=true`; `httpHostHeader=pokernight.levangie.org`; `originServerName=pokernight.levangie.org` |
| 12 | `pics.levangie.org` | `none` | `http://k3s-prod.levangie.dev` | `noTLSVerify=true` |
| 13 | `swingspot.levangie.dev` | `none` | `https://caddy` | `noTLSVerify=true`; `httpHostHeader=swingspot.levangie.dev`; `originServerName=swingspot.levangie.dev` |
| 14 | `cloud.levangie.org` | `none` | `https://k3s-prod.levangie.dev` | `noTLSVerify=true`; `httpHostHeader=cloud.levangie.org`; `originServerName=cloud.levangie.org` |
| 15 | `vw.levangie.dev` | `none` | `https://k3s-prod.levangie.dev` | `noTLSVerify=true`; `httpHostHeader=vw.levangie.dev`; `originServerName=vw.levangie.dev` |
| 16 | `dressindex.levangie.org` | `none` | `https://caddy` | `noTLSVerify=true`; `httpHostHeader=dressindex.levangie.org`; `originServerName=dressindex.levangie.org` |
| 17 | `ntfy.levangie.dev` | `none` | `https://k3s-prod.levangie.dev` | `noTLSVerify=true`; `httpHostHeader=ntfy.levangie.dev`; `originServerName=ntfy.levangie.dev` |
| 18 | `paperless.levangie.dev` | `none` | `https://k3s-prod.levangie.dev` | none |
| 19 | `request.levangie.dev` | `none` | `https://k3s-prod.levangie.dev` | none |
| 20 | `bin.levangie.dev` | `none` | `https://k3s-prod.levangie.dev` | none |
| 21 | `library.levangie.dev` | `none` | `https://k3s-prod.levangie.dev` | none |
| 22 | `vw.levangie.org` | `none` | `https://k3s-prod.levangie.dev` | none |
| 23 | `plausible.levangie.dev` | `none` | `https://k3s-prod.levangie.dev` | none |
| 24 | `kayleewatkins.com` | `none` | `https://k3s-prod.levangie.dev` | none |
| 25 | `join.levangie.dev` | `none` | `https://k3s-prod.levangie.dev` | `noTLSVerify=true`; `httpHostHeader=join.levangie.dev`; `originServerName=join.levangie.dev` |
| 26 | `seerr.levangie.org` | `none` | `https://k3s-prod.levangie.dev` | `noTLSVerify=true`; `httpHostHeader=seerr.levangie.org`; `originServerName=seerr.levangie.org` |
| 27 | `cloud.levangie.dev` | `none` | `https://k3s-prod.levangie.dev` | `noTLSVerify=true`; `httpHostHeader=cloud.levangie.dev`; `originServerName=cloud.levangie.dev` |
| 28 | `files.levangie.dev` | `none` | `https://k3s-prod.levangie.dev` | `noTLSVerify=true`; `httpHostHeader=files.levangie.dev`; `originServerName=files.levangie.dev` |
| 29 | `<catch-all>` | `none` | `http_status:404` | none |

The final rule is `http_status:404`; order must be preserved. `cloud.levangie.dev` and `files.levangie.dev` were added after the initial inventory for FileBrowser Quantum and Pingvin Share X. No secret-bearing fields were present in the returned ingress configuration.

## Relevant public DNS inventory

| zone | zone ID | record ID | type | name | target | proxied | TTL |
|---|---|---|---|---|---|---:|---:|
| `kayleewatkins.com` | `39ee0a0a603ced148623c30a24c55eba` | `6ba12cf9e5a6dc42789be39e17a0741a` | `CNAME` | `kayleewatkins.com` | `e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com` | `true` | `1` |
| `lazydj.xyz` | `9e6341a3f1dfd5ec70da3fe303212e89` | `323003a091391414f61df8cc536212be` | `CNAME` | `lazydj.xyz` | `e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com` | `true` | `1` |
| `levangie.dev` | `2a78e16b4af72edb6058ea4127aee9cd` | `8b8cc38d59631365e3c50d2b10462d99` | `CNAME` | `bin.levangie.dev` | `e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com` | `true` | `1` |
| `levangie.dev` | `2a78e16b4af72edb6058ea4127aee9cd` | `6c9385ac24c394bece9ae78c38bdac01` | `CNAME` | `cloud.levangie.dev` | `e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com` | `true` | `1` |
| `levangie.dev` | `2a78e16b4af72edb6058ea4127aee9cd` | `8169276a077a8a60f18e90670578e6fd` | `CNAME` | `files.levangie.dev` | `e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com` | `true` | `1` |
| `levangie.dev` | `2a78e16b4af72edb6058ea4127aee9cd` | `9e34692eeee3ed2a223d180357ec37f7` | `CNAME` | `join.levangie.dev` | `e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com` | `true` | `1` |
| `levangie.dev` | `2a78e16b4af72edb6058ea4127aee9cd` | `f10b4cf734a4e7879591e78ec9e432e0` | `CNAME` | `library.levangie.dev` | `e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com` | `true` | `1` |
| `levangie.dev` | `2a78e16b4af72edb6058ea4127aee9cd` | `4e32d133688a037b9a8292b257743a86` | `CNAME` | `ntfy.levangie.dev` | `e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com` | `true` | `1` |
| `levangie.dev` | `2a78e16b4af72edb6058ea4127aee9cd` | `0f63bbe5ed63f98cc80ce4009e9fed3b` | `CNAME` | `paperless.levangie.dev` | `e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com` | `true` | `1` |
| `levangie.dev` | `2a78e16b4af72edb6058ea4127aee9cd` | `0aa6c7d1419f63b0966fc1e24630692c` | `CNAME` | `plausible.levangie.dev` | `e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com` | `true` | `1` |
| `levangie.dev` | `2a78e16b4af72edb6058ea4127aee9cd` | `13c0c508e0db6fc11d09165d453f697d` | `CNAME` | `request.levangie.dev` | `e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com` | `true` | `1` |
| `levangie.dev` | `2a78e16b4af72edb6058ea4127aee9cd` | `02ab58d0355669d136082c71dd76f1d9` | `CNAME` | `swingspot.levangie.dev` | `e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com` | `true` | `1` |
| `levangie.dev` | `2a78e16b4af72edb6058ea4127aee9cd` | `0b926c7c548ab743cc82b6d56fac2ced` | `CNAME` | `vw.levangie.dev` | `e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com` | `true` | `1` |
| `levangie.org` | `620ef49385ca465ce84f6f70c4ec37ca` | `249f60b746713d3dc7f73ad1b5619704` | `CNAME` | `3dprintcalc.levangie.org` | `e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com` | `true` | `1` |
| `levangie.org` | `620ef49385ca465ce84f6f70c4ec37ca` | `4bde4f8ef0367fa3ce5887e038d88a9a` | `CNAME` | `affirmation.levangie.org` | `e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com` | `true` | `1` |
| `levangie.org` | `620ef49385ca465ce84f6f70c4ec37ca` | `3fa9cf183b62fb60db4fc6434cab803f` | `CNAME` | `auth.levangie.org` | `e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com` | `true` | `1` |
| `levangie.org` | `620ef49385ca465ce84f6f70c4ec37ca` | `fa6aa708824975fb63da5ae0633fe468` | `CNAME` | `bin.levangie.org` | `e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com` | `true` | `1` |
| `levangie.org` | `620ef49385ca465ce84f6f70c4ec37ca` | `c15f187481c70634ba84bd8883a53c34` | `CNAME` | `cloud.levangie.org` | `e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com` | `true` | `1` |
| `levangie.org` | `620ef49385ca465ce84f6f70c4ec37ca` | `c3bdc30c3f424139b8e61c79acdb0c49` | `CNAME` | `cs.levangie.org` | `e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com` | `true` | `1` |
| `levangie.org` | `620ef49385ca465ce84f6f70c4ec37ca` | `eb904cbad63eae5cb2989663d68a39aa` | `CNAME` | `dressindex.levangie.org` | `dressindex.pages.dev` | `true` | `1` |
| `levangie.org` | `620ef49385ca465ce84f6f70c4ec37ca` | `c9e51bfdc5267ae886d4ebb505f1bffe` | `CNAME` | `guac.levangie.org` | `e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com` | `true` | `1` |
| `levangie.org` | `620ef49385ca465ce84f6f70c4ec37ca` | `5ba1e60937a5952699794c56fb228942` | `CNAME` | `hass.levangie.org` | `e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com` | `true` | `1` |
| `levangie.org` | `620ef49385ca465ce84f6f70c4ec37ca` | `13cc9a67d416aeca7aec41dac52d7dc0` | `CNAME` | `memos.levangie.org` | `e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com` | `true` | `1` |
| `levangie.org` | `620ef49385ca465ce84f6f70c4ec37ca` | `c68ff39346d8263d5917945bb100597f` | `CNAME` | `photos.levangie.org` | `e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com` | `true` | `1` |
| `levangie.org` | `620ef49385ca465ce84f6f70c4ec37ca` | `70fe7b5b37455c775035a8eba0fe64ad` | `CNAME` | `pics.levangie.org` | `e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com` | `true` | `1` |
| `levangie.org` | `620ef49385ca465ce84f6f70c4ec37ca` | `6f672e588de872f050f45e7f35a0bf2b` | `CNAME` | `pokernight.levangie.org` | `e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com` | `true` | `1` |
| `levangie.org` | `620ef49385ca465ce84f6f70c4ec37ca` | `e242b705943985ff18c477dd9e79f40b` | `CNAME` | `request.levangie.org` | `e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com` | `true` | `1` |
| `levangie.org` | `620ef49385ca465ce84f6f70c4ec37ca` | `1c5a3adda4c0110ca6cc869898c0a2d8` | `CNAME` | `seerr.levangie.org` | `e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com` | `true` | `1` |
| `levangie.org` | `620ef49385ca465ce84f6f70c4ec37ca` | `109dcbb203381eac97fcc888ecc1f8d4` | `A` | `vw.levangie.org` | `172.20.20.200` | `false` | `1` |

All 29 route hostnames have an exact-name DNS record. IDs are operational identifiers, not credentials.
