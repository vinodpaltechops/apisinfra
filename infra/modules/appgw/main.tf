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

  # ── TLS switch ──────────────────────────────────────────────────────────────
  # enable_https = false → ONE listener on :80 serving the app. This is a
  #                        complete, working configuration, not a broken one.
  # enable_https = true  → a :443 listener plus, depending on
  #                        http_redirect_to_https, either a 301 on :80 or :80
  #                        continuing to serve the app alongside :443.
  #
  # Flipping the flag back and forth is non-destructive: it only adds/removes
  # listeners and rules on the existing gateway, so the public IP and therefore
  # the DNS record are untouched.
  tls_enabled = var.enable_https

  # Where the certificate comes from. Exactly one is used, enforced by the
  # variable validation in variables.tf:
  #   pfx        — Terraform uploads the PFX inline (no Key Vault involved)
  #   key_vault  — the gateway reads it from Key Vault at runtime
  cert_from_pfx       = var.enable_https && var.ssl_certificate_pfx_path != null
  cert_from_key_vault = var.enable_https && var.ssl_certificate_key_vault_secret_id != null

  # The identity exists only to read the certificate out of Key Vault, so it is
  # pointless in the inline-PFX case.
  create_identity = local.cert_from_key_vault

  # :80 serves the app whenever HTTPS is off, or when HTTPS is on but the
  # caller explicitly asked to keep plain HTTP working alongside it.
  http_serves_app = !local.tls_enabled || !var.http_redirect_to_https

  # Azure splits the source of an NSG rule across two mutually exclusive fields:
  #   source_address_prefix  (singular) — ONE value, and the only one that
  #                                       accepts service tags (Internet,
  #                                       VirtualNetwork, ...) or "*"
  #   source_address_prefixes (plural)  — a list, real CIDRs/IPs ONLY
  #
  # Putting a service tag in the plural form is rejected at apply time, not at
  # plan time:
  #   SecurityRuleParameterContainsUnsupportedValue: ... cannot specify
  #   existing VIRTUALNETWORK, INTERNET, AZURELOADBALANCER, '*' or system tags
  #
  # So detect which form the caller gave us. A single entry that is not parseable
  # as a CIDR is treated as a service tag and routed to the singular field;
  # anything else goes to the plural list.
  web_source_tag = (
    length(var.allowed_source_prefixes) == 1 &&
    !can(cidrhost(var.allowed_source_prefixes[0], 0))
  ) ? var.allowed_source_prefixes[0] : null
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

  # The actual public traffic. Narrow allowed_source_prefixes to your own IP
  # while testing if you would rather not be internet-facing straight away.
  # Exactly one of the two source fields is set — see local.web_source_tag.
  security_rule {
    name                       = "allow-web-inbound"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = local.web_source_tag
    source_address_prefixes    = local.web_source_tag == null ? var.allowed_source_prefixes : null
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

# ── Identity for reading the certificate from Key Vault ───────────────────────
# Created here rather than asked for as an input: it exists solely to serve this
# gateway, and creating it in the module means the role assignment below is
# managed too. Hand-creating either with `az` and ALSO letting Terraform create
# it fails the next apply with RoleAssignmentExists.
#
# Not created for the inline-PFX source — there is no vault to read from.
resource "azurerm_user_assigned_identity" "appgw" {
  count               = local.create_identity ? 1 : 0
  name                = "id-${local.name}"
  resource_group_name = var.hub_resource_group_name
  location            = var.location
  tags                = var.tags
}

# The vault uses RBAC (enable_rbac_authorization = true), so this is the whole
# grant — there is no access policy to add as well. Secrets User is sufficient:
# App Gateway fetches the certificate through the SECRET endpoint, which is why
# the input is a secret ID rather than a certificate ID.
resource "azurerm_role_assignment" "appgw_kv_secrets" {
  count                = local.create_identity ? 1 : 0
  scope                = var.key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.appgw[0].principal_id
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

  # MANDATORY. Left unset, Azure applies the 2015 default policy, which permits
  # TLS 1.0/1.1, and then refuses to create the gateway:
  #   ApplicationGatewayDeprecatedTlsVersionUsedInSslPolicy
  #
  # Note this applies even to an HTTP-only gateway — the policy is gateway-wide,
  # not per-listener, so it is validated whether or not a TLS listener exists.
  ssl_policy {
    policy_type = "Predefined"
    policy_name = var.ssl_policy_name
  }

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

  # Two mutually exclusive sources — see the variables for the trade-off.
  # Key Vault: fetched at runtime via the identity below; the private key never
  # enters Terraform state.
  dynamic "ssl_certificate" {
    for_each = local.cert_from_key_vault ? [1] : []
    content {
      name                = local.ssl_cert_name
      key_vault_secret_id = var.ssl_certificate_key_vault_secret_id
    }
  }

  # Inline PFX: no vault and no identity needed, so this works from a runner
  # with no route to a private Key Vault. The PFX does land in state.
  dynamic "ssl_certificate" {
    for_each = local.cert_from_pfx ? [1] : []
    content {
      name     = local.ssl_cert_name
      data     = filebase64(var.ssl_certificate_pfx_path)
      password = var.ssl_certificate_pfx_password
    }
  }

  dynamic "identity" {
    for_each = local.create_identity ? [1] : []
    content {
      type         = "UserAssigned"
      identity_ids = [azurerm_user_assigned_identity.appgw[0].id]
    }
  }

  # ── Routing ────────────────────────────────────────────────────────────────
  # Three supported shapes, driven entirely by the two toggles:
  #
  #   enable_https=false                   :80 → app
  #   enable_https=true,  redirect=true    :80 → 301 → :443 → app   (default)
  #   enable_https=true,  redirect=false   :80 → app, :443 → app    (both work)
  #
  # The redirect_configuration only exists in the middle case; in the third,
  # :80 keeps its own rule to the backend pool.
  dynamic "redirect_configuration" {
    for_each = local.tls_enabled && var.http_redirect_to_https ? [1] : []
    content {
      name                 = local.redirect_name
      redirect_type        = "Permanent"
      target_listener_name = local.listener_https
      include_path         = true
      include_query_string = true
    }
  }

  # :80 — serves the app, or redirects, but never both.
  request_routing_rule {
    name                        = "rule-http"
    priority                    = 100 # required on v2 SKUs
    rule_type                   = "Basic"
    http_listener_name          = local.listener_http
    backend_address_pool_name   = local.http_serves_app ? local.backend_pool : null
    backend_http_settings_name  = local.http_serves_app ? local.backend_setting : null
    redirect_configuration_name = local.http_serves_app ? null : local.redirect_name
  }

  # :443 — only exists when TLS is on.
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

  lifecycle {
    # Cross-variable checks — a variable validation block can only see its own
    # variable, so the "exactly one certificate source" rule lives here. These
    # fail at PLAN time, which is the whole point: the alternative is finding
    # out 20 minutes into an apply.
    precondition {
      condition     = !var.enable_https || local.cert_from_pfx != local.cert_from_key_vault
      error_message = "enable_https = true needs exactly ONE certificate source: either ssl_certificate_pfx_path or ssl_certificate_key_vault_secret_id, not both and not neither."
    }

    precondition {
      condition     = !local.cert_from_key_vault || var.key_vault_id != null
      error_message = "ssl_certificate_key_vault_secret_id requires key_vault_id — the module needs the vault's resource ID to grant its identity Key Vault Secrets User."
    }

    precondition {
      condition     = !local.cert_from_pfx || var.ssl_certificate_pfx_password != null
      error_message = "ssl_certificate_pfx_path requires ssl_certificate_pfx_password. Pass \"\" if the PFX was exported without a password."
    }
  }
}
