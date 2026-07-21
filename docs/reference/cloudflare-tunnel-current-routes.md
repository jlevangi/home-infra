# Cloudflare Tunnel current routes

Inventory status: **blocked** as of 2026-07-21.

The dedicated account-scoped token path `kv/prod/cloudflare-iac` does not exist. The existing token at `kv/prod/cloudflare` is DNS-scoped and is not authoritative for account or tunnel inventory. Route hostnames, order, paths, origin options, and tunnel IDs are therefore intentionally absent from this document.

## Verified connector baseline

- Connector host: LXC `172.20.20.254`
- Service state: active and enabled
- Version: `2024.8.3`
- Mode: remotely managed `tunnel run --token <redacted>`
- Local `/etc/cloudflared/config.yml`: absent
- Highest rule index observed in recent logs: `24` (at least 25 ordered rules)
- K3s Ingress hosts: 76 unique hosts; this is not a public-route allowlist
- Common origin: `https://k3s-prod.levangie.dev` / `172.20.20.200`

## Required inventory action

Create `kv/prod/cloudflare-iac` with key `CLOUDFLARE_API_TOKEN`, scoped to Pierce's account and approved zones with:

- Account / Cloudflare Tunnel / Edit
- Zone / DNS / Edit
- Zone / Zone / Read

Then export, without credentials or tokens:

1. `GET /accounts/<account-id>/cfd_tunnel`
2. `GET /accounts/<account-id>/cfd_tunnel/<tunnel-id>/configurations`
3. DNS records for each referenced zone

Do not build connector routes, Terraform DNS resources, or a cutover plan until this export and dashboard order agree.
