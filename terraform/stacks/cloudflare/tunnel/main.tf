terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "= 5.27.0"
    }
  }
}

variable "cloudflare_api_token" {
  type        = string
  description = "Cloudflare API token for managing resources"
  sensitive   = true
}

variable "account_id" {
  type        = string
  description = "Cloudflare Account ID"
  default     = "e0e043685655b3d2d63201a6c84fc409"
}

locals {
  static_ingress = [
    { hostname = "tunnel-test.levangie.dev", service = "hello_world" },
    { hostname = "hass.levangie.org", service = "https://caddy", origin_request = { http_host_header = "hass.levangie.org", origin_server_name = "hass.levangie.org" } },
    { hostname = "request.levangie.org", service = "https://request.levangie.dev", origin_request = { no_tls_verify = true, http_host_header = "request.levangie.org", origin_server_name = "request.levangie.org" } },
    { hostname = "photos.levangie.org", service = "https://k3s-prod.levangie.dev", origin_request = { no_tls_verify = true, http_host_header = "", origin_server_name = "" } },
    { hostname = "guac.levangie.org", service = "http://172.20.20.26:8080" },
    { hostname = "auth.levangie.org", service = "https://k3s-prod.levangie.dev", origin_request = { no_tls_verify = true, http_host_header = "auth.levangie.org", origin_server_name = "auth.levangie.org" } },
    { hostname = "cs.levangie.org", service = "https://caddy", origin_request = { no_tls_verify = true, http_host_header = "cs.levangie.org", origin_server_name = "cs.levangie.org" } },
    { hostname = "3dprintcalc.levangie.org", service = "https://caddy", origin_request = { no_tls_verify = true, http_host_header = "3dprintcalc.levangie.org", origin_server_name = "3dprintcalc.levangie.org" } },
    { hostname = "bin.levangie.org", service = "https://k3s-prod.levangie.dev", origin_request = { no_tls_verify = true, http_host_header = "bin.levangie.org", origin_server_name = "bin.levangie.org" } },
    { hostname = "lazydj.xyz", service = "https://caddy", origin_request = { origin_server_name = "lazydj.xyz" } },
    { hostname = "memos.levangie.org", service = "https://k3s-prod.levangie.dev", origin_request = { no_tls_verify = true, http_host_header = "memos.levangie.org", origin_server_name = "memos.levangie.org" } },
    { hostname = "affirmation.levangie.org", service = "https://caddy", origin_request = { no_tls_verify = true, http_host_header = "affirmation.levangie.org", origin_server_name = "affirmation.levangie.org" } },
    { hostname = "pokernight.levangie.org", service = "https://k3s-prod.levangie.dev", origin_request = { no_tls_verify = true, http_host_header = "pokernight.levangie.org", origin_server_name = "pokernight.levangie.org" } },
    { hostname = "pics.levangie.org", service = "http://k3s-prod.levangie.dev", origin_request = { no_tls_verify = true } },
    { hostname = "swingspot.levangie.dev", service = "https://caddy", origin_request = { no_tls_verify = true, http_host_header = "swingspot.levangie.dev", origin_server_name = "swingspot.levangie.dev" } },
    { hostname = "cloud.levangie.org", service = "https://k3s-prod.levangie.dev", origin_request = { no_tls_verify = true, http_host_header = "cloud.levangie.org", origin_server_name = "cloud.levangie.org" } },
    { hostname = "vw.levangie.dev", service = "https://k3s-prod.levangie.dev", origin_request = { no_tls_verify = true, http_host_header = "vw.levangie.dev", origin_server_name = "vw.levangie.dev" } },
    { hostname = "dressindex.levangie.org", service = "https://caddy", origin_request = { no_tls_verify = true, http_host_header = "dressindex.levangie.org", origin_server_name = "dressindex.levangie.org" } },
    { hostname = "ntfy.levangie.dev", service = "https://k3s-prod.levangie.dev", origin_request = { no_tls_verify = true, http_host_header = "ntfy.levangie.dev", origin_server_name = "ntfy.levangie.dev" } },
    { hostname = "paperless.levangie.dev", service = "https://k3s-prod.levangie.dev" },
    { hostname = "request.levangie.dev", service = "https://k3s-prod.levangie.dev" },
    { hostname = "bin.levangie.dev", service = "https://k3s-prod.levangie.dev" },
    { hostname = "library.levangie.dev", service = "https://k3s-prod.levangie.dev" },
    { hostname = "vw.levangie.org", service = "https://k3s-prod.levangie.dev" },
    { hostname = "plausible.levangie.dev", service = "https://k3s-prod.levangie.dev" },
    { hostname = "kayleewatkins.com", service = "https://k3s-prod.levangie.dev" },
    { hostname = "join.levangie.dev", service = "https://k3s-prod.levangie.dev", origin_request = { no_tls_verify = true, http_host_header = "join.levangie.dev", origin_server_name = "join.levangie.dev" } },
    { hostname = "seerr.levangie.org", service = "https://k3s-prod.levangie.dev", origin_request = { no_tls_verify = true, http_host_header = "seerr.levangie.org", origin_server_name = "seerr.levangie.org" } },
    { hostname = "cloud.levangie.dev", service = "https://k3s-prod.levangie.dev", origin_request = { no_tls_verify = true, http_host_header = "cloud.levangie.dev", origin_server_name = "cloud.levangie.dev" } },
    { hostname = "share.levangie.dev", service = "https://k3s-prod.levangie.dev", origin_request = { no_tls_verify = true, http_host_header = "share.levangie.dev", origin_server_name = "share.levangie.dev" } },
    { hostname = "swipe.levangie.dev", service = "https://k3s-prod.levangie.dev" },
    { hostname = "everlyera.com", service = "https://k3s-prod.levangie.dev" },
    { hostname = "gallery.everlyera.com", service = "https://k3s-prod.levangie.dev", origin_request = { no_tls_verify = true, http_host_header = "gallery.everlyera.com", origin_server_name = "gallery.everlyera.com" } },
    { hostname = "gambleking.app", service = "https://k3s-prod.levangie.dev" },
    { hostname = "matrix.levangie.dev", service = "https://k3s-prod.levangie.dev" },
    { hostname = "ghostvector.levangie.dev", service = "https://k3s-prod.levangie.dev", origin_request = { no_tls_verify = true, http_host_header = "ghostvector.levangie.dev", origin_server_name = "ghostvector.levangie.dev" } },
    { hostname = "outline.levangie.dev", service = "https://k3s-prod.levangie.dev", origin_request = { no_tls_verify = true, http_host_header = "outline.levangie.dev", origin_server_name = "outline.levangie.dev" } },
    { hostname = "car-ingest.levangie.dev", service = "https://k3s-prod.levangie.dev", origin_request = { no_tls_verify = true, http_host_header = "car-ingest.levangie.dev", origin_server_name = "car-ingest.levangie.dev" } },
    { hostname = "relay-pierce-mint-vm.levangie.dev", service = "http://pierce-mint-vm.levangie.org:8375" },
    { hostname = "herdr.levangie.dev", service = "http://pierce-mint-vm.levangie.org:8375" },
    { hostname = "shelfmark.levangie.dev", service = "https://k3s-prod.levangie.dev", origin_request = { no_tls_verify = true, http_host_header = "shelfmark.levangie.dev", origin_server_name = "shelfmark.levanhie.dev" } },
    { hostname = "calibre.levangie.dev", service = "https://k3s-prod.levangie.dev", origin_request = { no_tls_verify = true, http_host_header = "calibre.levangie.dev", origin_server_name = "calibre.levangie.dev" } },
    { hostname = "audiobooks.levangie.dev", service = "https://k3s-prod.levangie.dev", origin_request = { no_tls_verify = true, http_host_header = "audiobooks.levangie.dev", origin_server_name = "audiobooks.levangie.dev" } },

  ]
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

resource "cloudflare_dns_record" "tunnel_test" {
  zone_id = "2a78e16b4af72edb6058ea4127aee9cd"
  name    = "tunnel-test"
  content = "e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com"
  type    = "CNAME"
  proxied = true
  ttl     = 1
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "maurice_config" {
  account_id = var.account_id
  tunnel_id  = "e163e2bb-e184-41aa-a96b-eb1dbdb99418"

  config = {
    # Explicit routes win; any other levangie.dev host that external-dns points at the tunnel goes to Traefik.
    ingress = concat(
      local.static_ingress,
      [
        { hostname = "*.levangie.dev", service = "https://k3s-prod.levangie.dev", origin_request = { match_sn_ito_host = true } },
        { service = "http_status:404" },
      ],
    )
  }
}
