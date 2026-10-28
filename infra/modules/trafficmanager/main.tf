# MODULE: trafficmanager
# Global entry point in front of the per-region Application Gateways, standing
# in for Front Door on subscriptions where Front Door is forbidden:
#
#   internet → app.<domain> (CNAME) → <profile>.trafficmanager.net
#            → DNS answer, PRIORITY-ordered
#                priority 1 → agw-dev-* public IP (southindia)
#                priority 2 → agw-dr-*  public IP (indiasouthcentral)
#            → App Gateway WAF_v2 → internal ingress LB → ingress-nginx → app
#
# ── Traffic Manager is DNS, not a proxy ───────────────────────────────────────
# This is the one thing to internalise, because every difference from the Front
# Door design follows from it. Front Door terminates the client's connection at
# an anycast edge and forwards it; the DNS answer never changes, so failover
# moves traffic inside a live connection. Traffic Manager only ANSWERS A QUERY.
# It hands back the healthy endpoint's address and is then out of the path
# entirely — the client connects straight to an App Gateway.
#
# Consequences, all of which are real and none of which are fixable here:
#   • Failover takes effect only as fast as clients re-resolve. The profile TTL
#     is a floor, not a guarantee: resolvers and browsers cache beyond it, and
#     some ignore it completely.
#   • In-flight connections BREAK on failover rather than migrating. A user
#     mid-request gets an error, then works on retry.
#   • There is no edge TLS and no edge WAF. Each gateway keeps its own OWASP
#     policy — the inspection did not move, it just never got centralised.
#   • Origins cannot be cloaked. Front Door could stamp X-Azure-FDID and have
#     the gateways reject anything without it. There is no equivalent, so both
#     gateway IPs stay directly reachable.
#
# What it buys: automatic failover, on a subscription tier that refuses Front
# Door, for a few dollars a month.

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
  name = "tm-${var.org_name}-001"

  # The relative name becomes <name>.trafficmanager.net, which is a single
  # global namespace shared by every Azure tenant. "vinorg-app" is exactly the
  # kind of name somebody else has already taken, and the failure arrives at
  # apply time as a flat conflict, so a random suffix is cheaper than the retry.
  relative_name = "${var.org_name}-app-${random_string.dns.result}"
}

resource "random_string" "dns" {
  length  = 6
  lower   = true
  upper   = false
  numeric = true
  special = false
}

resource "azurerm_traffic_manager_profile" "this" {
  name                   = local.name
  resource_group_name    = var.resource_group_name
  traffic_routing_method = "Priority"
  tags                   = var.tags

  dns_config {
    relative_name = local.relative_name

    # Half of the failover time; the other half is probe detection. 30s is the
    # practical floor — lower buys little, because client-side caching, not the
    # record, is what actually dominates. Raising it to the DNS-typical 300s
    # would add five minutes to every failover.
    ttl = var.ttl
  }

  monitor_config {
    protocol = var.health_probe_protocol
    port     = var.health_probe_port

    # Must be the app's real health endpoint. Probing / would report healthy
    # whenever nginx serves an error page — a failover that never triggers is
    # worse than having none, because you believe you are covered.
    path = var.health_probe_path

    # 30s standard, or 10s "fast probing" (billed as a separate line item).
    # Detection window = interval x (tolerated_failures + 1): 30 x 4 = ~2 min.
    # Tighter is not better — a transient blip that flaps traffic between
    # regions is worse than a brief 502 from one of them, and DNS failover
    # flaps badly because clients are still holding the old answer.
    interval_in_seconds          = var.health_probe_interval_seconds
    timeout_in_seconds           = var.health_probe_timeout_seconds
    tolerated_number_of_failures = var.tolerated_number_of_failures

    expected_status_code_ranges = var.expected_status_code_ranges

    # ── LOAD-BEARING. Without this, nothing works. ─────────────────────────────
    # Traffic Manager probes the endpoint's target — here a raw public IP — and
    # by default sends `Host: <that IP>`. The App Gateway listener is host-based
    # (host_name = app_fqdn in modules/appgw), so it has no rule matching an IP
    # and answers 404. Measured against the live gateway:
    #
    #   curl -H 'Host: app.sometestdemo.in' http://<gw-ip>/healthz  -> 200
    #   curl                                http://<gw-ip>/healthz  -> 404
    #
    # A 404 is outside expected_status_code_ranges, so EVERY endpoint goes
    # Degraded, and a profile whose endpoints are all degraded hands back the
    # priority-1 answer regardless — the failover silently stops working while
    # the app itself is still up and serving real users perfectly well.
    dynamic "custom_header" {
      for_each = var.probe_host_header == null ? [] : [var.probe_host_header]
      content {
        name  = "host"
        value = custom_header.value
      }
    }
  }
}

# ── Endpoints — one per region, ordered by priority ───────────────────────────
# External (not Azure) endpoints, targeting the gateway public IPs directly.
#
# Azure endpoints would bind to the public IP RESOURCE instead, which adds
# awareness of the resource being stopped or deleted — but they require a DNS
# label on every public IP and answer with a CNAME to *.cloudapp.azure.com,
# adding a resolution hop. The gateways have no DNS labels today, and the
# health probe already detects everything that matters: a gateway that is gone
# fails its probe just as surely as one that is broken.
resource "azurerm_traffic_manager_external_endpoint" "this" {
  for_each = var.endpoints

  name       = "endpoint-${each.key}"
  profile_id = azurerm_traffic_manager_profile.this.id
  target     = each.value.target
  enabled    = each.value.enabled

  # Under Priority routing, the LOWEST number that is Online takes 100% of
  # traffic. Nothing is shared between regions in normal operation: the standby
  # is sized for failover, not for half the load.
  priority = each.value.priority

  # Only read by Performance routing, which picks the closest endpoint by
  # latency. Recorded anyway — it is the only place the endpoint's region is
  # visible in the profile, and it costs nothing under Priority.
  endpoint_location = each.value.location
}
