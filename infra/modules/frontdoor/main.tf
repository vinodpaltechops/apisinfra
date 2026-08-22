# MODULE: frontdoor
# Global anycast entry point in front of the per-region Application Gateways.
# This is the thing that makes the two regions one service:
#
#   internet → app.<domain> (CNAME) → Front Door edge (anycast, ~100 PoPs)
#            → origin group, PRIORITY-ordered
#                priority 1 → agw-dev-* public IP (southindia)
#                priority 2 → agw-dr-*  public IP (centralindia)
#            → App Gateway WAF_v2 → internal ingress LB → ingress-nginx → app
#
# ── Why Front Door and not Traffic Manager ────────────────────────────────────
# Traffic Manager fails over via DNS, so recovery time is bounded below by the
# record TTL plus however long resolvers and clients actually cache it — in
# practice minutes, and some clients far longer. Front Door fails over inside a
# live TCP connection at the edge: the client's DNS answer never changes,
# because the anycast address never changes. For an active-passive DR posture
# that difference IS the RTO.
#
# ── Failover semantics ────────────────────────────────────────────────────────
# Origins are PRIORITY-based, not weighted. All traffic goes to priority 1
# while its health probe passes; the moment it fails, everything shifts to
# priority 2. Nothing is load-balanced across regions in normal operation,
# which is deliberate — the DR cluster is a warm standby sized for failover,
# not half the production load.

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
    # Declared here as well as in the calling layer: a module that uses a
    # provider must require it, or it silently inherits whatever the root
    # happens to have and breaks the first time it is called from elsewhere.
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

locals {
  name = "afd-${var.org_name}-001"

  # Endpoint names become part of the *.azurefd.net hostname, so they must be
  # globally unique. The random suffix avoids a collision with any other tenant
  # that also called theirs "contoso-app".
  endpoint_name = "fde-${var.org_name}-${random_string.endpoint.result}"
}

resource "random_string" "endpoint" {
  length  = 6
  lower   = true
  upper   = false
  numeric = true
  special = false
}

resource "azurerm_cdn_frontdoor_profile" "this" {
  name                = local.name
  resource_group_name = var.resource_group_name
  sku_name            = var.sku_name
  tags                = var.tags

  # How long Front Door waits for the origin to send response headers. Kept
  # above the App Gateway's own 30s backend request_timeout so the gateway's
  # timeout is always the one that fires — one timeout owns the behaviour, and
  # its error is the more specific of the two.
  response_timeout_seconds = var.response_timeout_seconds
}

resource "azurerm_cdn_frontdoor_endpoint" "this" {
  name                     = local.endpoint_name
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.this.id
  tags                     = var.tags
}

# ── Origin group: health probing + failover policy ────────────────────────────
resource "azurerm_cdn_frontdoor_origin_group" "this" {
  name                     = "og-appgw"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.this.id

  # Drain time when an origin is disabled or removed — lets in-flight requests
  # finish instead of being cut off mid-response during a planned failover.
  restore_traffic_time_to_healed_or_new_endpoint_in_minutes = 5

  health_probe {
    # Same endpoint the App Gateway probes, so "healthy" means the same thing at
    # both tiers: the frontend pod answered, not merely that a port is open.
    path     = var.health_probe_path
    protocol = var.health_probe_protocol

    # HEAD is cheaper than GET, but it silently reports healthy against origins
    # that only implement GET. The app's /healthz answers both, so HEAD is safe
    # here — switch to GET if you ever point this at something else.
    request_type = "HEAD"

    # Front Door probes from MANY edge PoPs. At 30s each that is a meaningful
    # and constant request rate against /healthz; do not lower it casually.
    interval_in_seconds = var.health_probe_interval_seconds
  }

  load_balancing {
    # 4 samples at 30s = the origin must be failing for ~2 minutes before Front
    # Door declares it down. Deliberately not tighter: a shorter window makes a
    # transient blip trigger a cross-region failover, and flapping between
    # regions is worse than a brief 502 from one.
    sample_size                 = 4
    successful_samples_required = 3

    # 0 ms enforces STRICT priority. Any positive value tells Front Door to
    # treat origins within that latency band as equivalent and spread traffic
    # across them — which would quietly turn this active-passive design into
    # active-active and start serving from a standby sized for neither.
    additional_latency_in_milliseconds = 0
  }
}

# ── Origins — one per region, ordered by priority ─────────────────────────────
resource "azurerm_cdn_frontdoor_origin" "this" {
  for_each = var.origins

  name                          = "origin-${each.key}"
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.this.id
  enabled                       = each.value.enabled

  host_name  = each.value.host_name
  http_port  = 80
  https_port = 443

  # The Host header sent to the App Gateway. It MUST be the application's real
  # FQDN: the gateway's listener is host-based (host_name = app_fqdn) and its
  # backend setting re-sends that host to ingress-nginx, whose Ingress rule is
  # also host-based. Send the origin's IP here instead and every request 404s
  # at the ingress with the gateway still reporting Healthy.
  origin_host_header = var.app_fqdn

  priority = each.value.priority
  weight   = 1000 # irrelevant under strict priority; only used between equal-priority origins

  # ── Why name checking is off ────────────────────────────────────────────────
  # The origins are the gateways' PUBLIC IPs, and a certificate can never match
  # an IP that is not in its SAN list. With checking on, Front Door refuses the
  # origin TLS handshake and every request 503s.
  #
  # The connection is still TLS-encrypted over Azure's backbone; what is skipped
  # is verifying the origin's identity. The residual risk is an in-path attacker
  # between Front Door and the gateway — inside Azure's network, with the NSG
  # already restricted to AzureFrontDoor.Backend.
  #
  # To turn it on: give each gateway its own DNS name (origin-sin.<domain>,
  # origin-cin.<domain>), point those at the gateway IPs, issue a certificate
  # whose SAN covers both, and set this true with host_name set to those names.
  certificate_name_check_enabled = var.origin_certificate_name_check_enabled
}

# ── Custom domain — app.<domain>, with an Azure-managed certificate ───────────
resource "azurerm_cdn_frontdoor_custom_domain" "this" {
  name                     = replace(var.app_fqdn, ".", "-")
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.this.id
  host_name                = var.app_fqdn

  tls {
    # Azure issues AND auto-renews this one. The App Gateway certificate in Key
    # Vault is a separate thing and still required — it terminates the
    # Front-Door-to-origin leg, this one terminates the client-to-edge leg.
    certificate_type    = "ManagedCertificate"
    minimum_tls_version = "TLS12"
  }
}

# ── Route ─────────────────────────────────────────────────────────────────────
resource "azurerm_cdn_frontdoor_route" "this" {
  name                            = "route-app"
  cdn_frontdoor_endpoint_id       = azurerm_cdn_frontdoor_endpoint.this.id
  cdn_frontdoor_origin_group_id   = azurerm_cdn_frontdoor_origin_group.this.id
  cdn_frontdoor_origin_ids        = [for o in azurerm_cdn_frontdoor_origin.this : o.id]
  cdn_frontdoor_custom_domain_ids = [azurerm_cdn_frontdoor_custom_domain.this.id]

  enabled                = true
  forwarding_protocol    = var.forwarding_protocol
  https_redirect_enabled = true
  patterns_to_match      = ["/*"]
  supported_protocols    = ["Http", "Https"]

  # false so the app is served ONLY on the custom domain. Left true, the same
  # content is also reachable at <endpoint>.azurefd.net — a second public
  # hostname nobody monitors, outside the certificate, and invisible to any
  # WAF rule written against the real Host header.
  link_to_default_domain = false

  cache {
    # The app is a React SPA plus two JSON APIs. Caching the API responses at
    # the edge would serve stale content across a failover, so only genuinely
    # static asset types are cached.
    compression_enabled = true
    content_types_to_compress = [
      "text/html", "text/css", "text/javascript",
      "application/javascript", "application/json", "image/svg+xml",
    ]
    query_string_caching_behavior = "IgnoreQueryString"
  }

  depends_on = [azurerm_cdn_frontdoor_custom_domain.this]
}

# Binding the domain to the route is what triggers Azure's domain-ownership
# validation and managed-certificate issuance. Until the _dnsauth TXT record
# exists (see the dns_records output), the domain sits in "Pending" and the
# route serves nothing on it.
resource "azurerm_cdn_frontdoor_custom_domain_association" "this" {
  cdn_frontdoor_custom_domain_id = azurerm_cdn_frontdoor_custom_domain.this.id
  cdn_frontdoor_route_ids        = [azurerm_cdn_frontdoor_route.this.id]
}
