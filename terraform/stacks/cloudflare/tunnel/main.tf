terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "= 5.27.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "= 3.3.0"
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
  legacy_tunnel_hosts = [for route in local.static_ingress : route.hostname]
  exposure_annotation = "cloudflare-tunnel.levangie.dev/exposure"
  ingresses           = flatten([for ns in data.kubernetes_resources.ingresses : ns.objects])
  ingress_hosts = flatten([
    for ingress in local.ingresses : [
      for rule in try(ingress.spec.rules, []) : {
        name     = "${ingress.metadata.namespace}/${ingress.metadata.name}"
        host     = try(rule.host, "")
        exposure = try(ingress.metadata.annotations[local.exposure_annotation], "unset")
      }
    ]
  ])
  exposure_hosts = toset([for rule in local.ingress_hosts : rule.host if rule.exposure == "external"])
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
provider "kubernetes" {}

# Every Ingress in the cluster; ArgoCD has already rendered and applied them.
# kubernetes_resources cannot list across namespaces (provider issue #2849), so read each namespace.
data "kubernetes_resources" "namespaces" {
  api_version = "v1"
  kind        = "Namespace"
}

data "kubernetes_resources" "ingresses" {
  for_each    = toset([for ns in data.kubernetes_resources.namespaces.objects : ns.metadata.name])
  api_version = "networking.k8s.io/v1"
  kind        = "Ingress"
  namespace   = each.key
}

resource "cloudflare_dns_record" "exposure" {
  for_each = local.exposure_hosts
  zone_id  = "2a78e16b4af72edb6058ea4127aee9cd"
  name     = each.key
  content  = "e163e2bb-e184-41aa-a96b-eb1dbdb99418.cfargotunnel.com"
  type     = "CNAME"
  proxied  = true
  ttl      = 1
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
    ingress = concat(
      local.static_ingress,
      [for host in sort(local.exposure_hosts) : {
        hostname = host
        service  = "https://k3s-prod.levangie.dev"
        origin_request = {
          no_tls_verify      = false
          http_host_header   = host
          origin_server_name = host
        }
      }],
      [{ service = "http_status:404" }],
    )
  }

  lifecycle {
    precondition {
      condition     = length(local.ingresses) > 0
      error_message = "Read zero Ingresses from the cluster; refusing to unpublish every annotated host."
    }
    precondition {
      condition     = alltrue([for rule in local.ingress_hosts : contains(["external", "internal", "unset"], rule.exposure)])
      error_message = "Invalid ${local.exposure_annotation} value on: ${join(", ", distinct([for rule in local.ingress_hosts : rule.name if !contains(["external", "internal", "unset"], rule.exposure)]))}"
    }
    precondition {
      condition     = alltrue([for host in local.exposure_hosts : can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+levangie\\.dev$", host))])
      error_message = "External hosts must be explicit hosts under levangie.dev."
    }
    precondition {
      condition     = alltrue([for rule in local.ingress_hosts : !contains(local.legacy_tunnel_hosts, rule.host) if rule.exposure != "unset"])
      error_message = "Annotated host is a legacy static route; migrate it out of local.static_ingress first."
    }
    # A tunnel route publishes the whole hostname, so every Ingress sharing it must agree.
    precondition {
      condition     = alltrue([for rule in local.ingress_hosts : rule.exposure == "external" if contains(local.exposure_hosts, rule.host)])
      error_message = "Host is external on one Ingress but not on another: ${join(", ", distinct([for rule in local.ingress_hosts : rule.host if contains(local.exposure_hosts, rule.host) && rule.exposure != "external"]))}"
    }
  }
}
