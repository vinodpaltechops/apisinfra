# MODULE: appgw
# Public entry point for the workload: Application Gateway WAF_v2 in the HUB,
# forwarding to the spoke's INTERNAL ingress load balancer.
#
#   internet → GoDaddy A record → this public IP
#            → App Gateway WAF_v2 (hub, 10.0.7.0/24)
#            → 10.1.2.250 internal LB (dev spoke)
#            → ingress-nginx → frontend / backend
#
# The cluster stays private end to end: the API server has no public endpoint,
# the nodes have no public IPs, and the only thing on the internet is this
# gateway. Traffic reaches the spoke over the existing hub↔spoke peering, and
# the spoke NSG already admits it via the allow-from-hub rule (10.0.0.0/16 →
# 10.1.0.0/16).
#
# Lives in the hub because a shared, WAF-fronted ingress is a platform concern
# in CAF — one gateway can serve several spokes by adding listeners.

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
  }
}

locals {
  name = "agw-${var.env}-${var.org_name}-001"

  # Names referenced across blocks — App Gateway wires its parts together by
  # name, so a single source of truth avoids a class of silent misconfigurations.
  frontend_ip         = "feip-public"
  frontend_port_http  = "feport-http"
  frontend_port_https = "feport-https"
  backend_pool        = "bepool-ingress"
  backend_setting     = "behttp-ingress"
  probe_name          = "probe-ingress"
  listener_http       = "listener-http"
  listener_https      = "listener-https"
  ssl_cert_name       = "cert-app"
  redirect_name       = "redirect-to-https"

  # TLS is optional so the gateway can be stood up and proven over HTTP before
  # a certificate exists. Supply the Key Vault secret ID to switch it on.
  tls_enabled = var.ssl_certificate_key_vault_secret_id != null
}

# ── Subnet — App Gateway v2 requires a DEDICATED subnet ───────────────────────
# Created here rather than in the connectivity layer's vnet module because this
# layer owns its own lifecycle. Safe because that module declares subnets as
# standalone azurerm_subnet resources, not inline blocks on the VNet — inline
# blocks would delete any subnet they don't manage.
resource "azurerm_subnet" "appgw" {
  name                 = "snet-appgw"
  resource_group_name  = var.hub_resource_group_name
  virtual_network_name = var.hub_vnet_name
  address_prefixes     = [var.subnet_address_prefix]
}

# ── NSG — the GatewayManager rule is mandatory ────────────────────────────────
# Without inbound 65200-65535 from the GatewayManager service tag, Azure cannot
# manage the gateway and it goes Unhealthy with no obvious cause. This is the
# single most common App Gateway misconfiguration.
resource "azurerm_network_security_group" "appgw" {
  name                = "nsg-${local.name}"
  resource_group_name = var.hub_resource_group_name
  location            = var.location
  tags                = var.tags

  security_rule {
    name                       = "allow-gateway-manager"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = "GatewayManager"
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_range     = "65200-65535"
  }

  security_rule {
    name                       = "allow-azure-lb"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_address_prefix      = "AzureLoadBalancer"
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_range     = "*"
  }

  # The actual public traffic. Narrow source_address_prefixes to your own IP
  # while testing if you would rather not be internet-facing straight away.
  security_rule {
    name                       = "allow-web-inbound"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefixes    = var.allowed_source_prefixes
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_ranges    = ["80", "443"]
  }
}

resource "azurerm_subnet_network_security_group_association" "appgw" {
  subnet_id                 = azurerm_subnet.appgw.id
  network_security_group_id = azurerm_network_security_group.appgw.id
}

# ── Public IP — must be Standard + Static for v2 ──────────────────────────────
# Static matters beyond availability: the GoDaddy A record points at this
# literal address, so it must survive restarts.
resource "azurerm_public_ip" "appgw" {
  name                = "pip-${local.name}"
  resource_group_name = var.hub_resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

# ── WAF policy ────────────────────────────────────────────────────────────────
# The modern replacement for the inline waf_configuration block: a policy is a
# separate resource that can be attached to several gateways or listeners.
resource "azurerm_web_application_firewall_policy" "appgw" {
  name                = "wafpol-${local.name}"
  resource_group_name = var.hub_resource_group_name
  location            = var.location
  tags                = var.tags

  policy_settings {
    enabled = true
    # Prevention blocks; Detection only logs. If a legitimate request is ever
    # rejected, switch to "Detection", reproduce it, read the firewall log to
    # find the rule ID, then add a targeted exclusion rather than disabling WAF.
    mode                        = var.waf_mode
    request_body_check          = true
    max_request_body_size_in_kb = 128
    file_upload_limit_in_mb     = 100
  }

  managed_rules {
    managed_rule_set {
      type    = "OWASP"
      version = "3.2"
    }
  }
}

# ── Application Gateway ───────────────────────────────────────────────────────
resource "azurerm_application_gateway" "this" {
  name                = local.name
  resource_group_name = var.hub_resource_group_name
  location            = var.location
  tags                = var.tags

  sku {
    name = "WAF_v2"
    tier = "WAF_v2"
    # No `capacity` when autoscaling. min 0 keeps the idle cost at the fixed
    # gateway charge instead of paying for a permanently running instance.
    # Raise min_capacity for production — scale-out from 0 adds latency.
  }

  autoscale_configuration {
    min_capacity = var.min_capacity
    max_capacity = var.max_capacity
  }

  firewall_policy_id = azurerm_web_application_firewall_policy.appgw.id

  gateway_ip_configuration {
    name      = "gwip"
    subnet_id = azurerm_subnet.appgw.id
  }

  frontend_ip_configuration {
    name                 = local.frontend_ip
    public_ip_address_id = azurerm_public_ip.appgw.id
  }

  frontend_port {
    name = local.frontend_port_http
    port = 80
  }

  dynamic "frontend_port" {
    for_each = local.tls_enabled ? [1] : []
    content {
      name = local.frontend_port_https
      port = 443
    }
  }

  # ── Backend: the spoke's internal ingress LB ────────────────────────────────
  backend_address_pool {
    name         = local.backend_pool
    ip_addresses = [var.ingress_internal_ip]
  }

  # host_name is set explicitly because the backend is an IP: without it the
  # gateway would send `Host: 10.1.2.250`, and any host-based Ingress rule
  # would fail to match.
  backend_http_settings {
    name                  = local.backend_setting
    cookie_based_affinity = "Disabled"
    port                  = 80
    protocol              = "Http"
    request_timeout       = 30
    host_name             = var.app_fqdn
    probe_name            = local.probe_name
  }

  # Probes the frontend pod's own health endpoint through the ingress, so an
  # unhealthy backend here means the actual app is down — not merely that a
  # TCP port is open.
  probe {
    name                                      = local.probe_name
    protocol                                  = "Http"
    path                                      = "/healthz"
    interval                                  = 30
    timeout                                   = 30
    unhealthy_threshold                       = 3
    pick_host_name_from_backend_http_settings = true

    match {
      status_code = ["200-399"]
    }
  }

  # ── Listeners ──────────────────────────────────────────────────────────────
  http_listener {
    name                           = local.listener_http
    frontend_ip_configuration_name = local.frontend_ip
    frontend_port_name             = local.frontend_port_http
    protocol                       = "Http"
    host_name                      = var.app_fqdn
  }

  dynamic "http_listener" {
    for_each = local.tls_enabled ? [1] : []
    content {
      name                           = local.listener_https
      frontend_ip_configuration_name = local.frontend_ip
      frontend_port_name             = local.frontend_port_https
      protocol                       = "Https"
      host_name                      = var.app_fqdn
      ssl_certificate_name           = local.ssl_cert_name
    }
  }

  # Certificate is read from Key Vault at runtime via the user-assigned
  # identity, so the PFX never lands in Terraform state.
  dynamic "ssl_certificate" {
    for_each = local.tls_enabled ? [1] : []
    content {
      name                = local.ssl_cert_name
      key_vault_secret_id = var.ssl_certificate_key_vault_secret_id
    }
  }

  dynamic "identity" {
    for_each = var.identity_id != null ? [1] : []
    content {
      type         = "UserAssigned"
      identity_ids = [var.identity_id]
    }
  }

  # ── Routing ────────────────────────────────────────────────────────────────
  # With TLS off: HTTP goes straight to the backend.
  # With TLS on:  HTTP permanently redirects to HTTPS, HTTPS serves the app.
  dynamic "redirect_configuration" {
    for_each = local.tls_enabled ? [1] : []
    content {
      name                 = local.redirect_name
      redirect_type        = "Permanent"
      target_listener_name = local.listener_https
      include_path         = true
      include_query_string = true
    }
  }

  request_routing_rule {
    name                        = "rule-http"
    priority                    = 100 # required on v2 SKUs
    rule_type                   = "Basic"
    http_listener_name          = local.listener_http
    backend_address_pool_name   = local.tls_enabled ? null : local.backend_pool
    backend_http_settings_name  = local.tls_enabled ? null : local.backend_setting
    redirect_configuration_name = local.tls_enabled ? local.redirect_name : null
  }

  dynamic "request_routing_rule" {
    for_each = local.tls_enabled ? [1] : []
    content {
      name                       = "rule-https"
      priority                   = 110
      rule_type                  = "Basic"
      http_listener_name         = local.listener_https
      backend_address_pool_name  = local.backend_pool
      backend_http_settings_name = local.backend_setting
    }
  }

  depends_on = [azurerm_subnet_network_security_group_association.appgw]
}
