terraform {
  required_version = ">=1.7.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
  }
  backend "azurerm" {
    resource_group_name  = "rg-tfstate-vinorg-001"
    storage_account_name = "stotfstatevinorgmjslia"
    container_name       = "firewall"
    key                  = "firewall.tfstate"
  }
}

locals {
  tags = {
    Name = "Firewall"
  }
}

data "azurerm_subnet" "firewall" {
  name                 = "AzureFirewallSubnet"
  resource_group_name  = azurerm_resource_group.hub.name
  virtual_network_name = module.hub_vnet.vnet_name

  depends_on = [azurerm_virtual_network.hub]
}

# ── Public IP for Firewall ─────────────────────────────────────────────────────
resource "azurerm_public_ip" "firewall" {
  name                = "pip-firewall-hub-lab"
  resource_group_name = azurerm_resource_group.hub.name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  # Empty list = regional (no zones). See var.availability_zones.
  zones               = var.availability_zones
  tags                = local.tags
}

# ── Firewall Policy ────────────────────────────────────────────────────────────
# Policy is separate from the firewall itself — this is the modern approach.
# Rules live in the policy, not inline on the firewall.
# This means you can update rules without touching the firewall resource.
resource "azurerm_firewall_policy" "hub" {
  name                = "afwp-hub-lab-001"
  resource_group_name = azurerm_resource_group.hub.name
  location            = var.location
  sku                 = "Standard"   # Standard for lab (Premium adds IDPS/TLS inspect)

  dns {
    proxy_enabled = true   # Firewall acts as DNS proxy for all spoke traffic
    # When enabled: spoke VMs send DNS to Firewall → Firewall forwards to DNS Resolver
    # This gives you DNS query visibility in firewall logs
  }

  tags = local.tags
}

# ── Rule Collection Group ──────────────────────────────────────────────────────
# Think of this as a folder of rules. Priority determines evaluation order.
# Lower number = evaluated first.
resource "azurerm_firewall_policy_rule_collection_group" "hub" {
  name               = "rcg-hub-lab"
  firewall_policy_id = azurerm_firewall_policy.hub.id
  priority           = 100

  # ── Network Rules ────────────────────────────────────────────────────────────
  # Network rules: IP/port/protocol matching (L4)
  # Evaluated BEFORE application rules
  # Use for: spoke-to-spoke, on-prem access, Azure service tags
  network_rule_collection {
    name     = "nrc-allow-spoke-to-spoke"
    priority = 100
    action   = "Allow"

    # Dev → QA (e.g. integration testing, API calls)
    rule {
      name                  = "allow-dev-to-qa"
      protocols             = ["TCP", "UDP"]
      source_addresses      = ["10.1.0.0/16"]   # dev spoke
      destination_addresses = ["10.2.0.0/16"]   # qa spoke
      destination_ports     = ["443", "80", "8080"]
    }

    # QA → Dev (bidirectional for callbacks)
    rule {
      name                  = "allow-qa-to-dev"
      protocols             = ["TCP"]
      source_addresses      = ["10.2.0.0/16"]
      destination_addresses = ["10.1.0.0/16"]
      destination_ports     = ["443", "80", "8080"]
    }

    # Prod is isolated — NO spoke-to-spoke rule for prod
    # prod traffic will be denied by default (implicit deny at end)
  }

  network_rule_collection {
    name     = "nrc-allow-azure-services"
    priority = 200
    action   = "Allow"

    # All spokes → Azure Monitor (needed for VM agents, AKS monitoring)
    rule {
      name                  = "allow-azure-monitor"
      protocols             = ["TCP"]
      source_addresses      = ["10.1.0.0/8"]    # covers all spoke ranges
      destination_addresses = ["AzureMonitor"]   # Azure service tag
      destination_ports     = ["443"]
    }

    # All spokes → Azure Key Vault
    rule {
      name                  = "allow-key-vault"
      protocols             = ["TCP"]
      source_addresses      = ["10.1.0.0/8"]
      destination_addresses = ["AzureKeyVault"]
      destination_ports     = ["443"]
    }

    # All spokes → Azure Container Registry (AKS image pulls)
    rule {
      name                  = "allow-acr"
      protocols             = ["TCP"]
      source_addresses      = ["10.1.0.0/8"]
      destination_addresses = ["AzureContainerRegistry"]
      destination_ports     = ["443"]
    }

    # All spokes → Azure Active Directory (auth)
    rule {
      name                  = "allow-aad"
      protocols             = ["TCP"]
      source_addresses      = ["10.1.0.0/8"]
      destination_addresses = ["AzureActiveDirectory"]
      destination_ports     = ["443"]
    }
  }

  network_rule_collection {
    name     = "nrc-deny-prod-isolation"
    priority = 300
    action   = "Deny"

    # Explicitly deny dev/qa → prod (defence in depth on top of RBAC)
    rule {
      name                  = "deny-dev-to-prod"
      protocols             = ["Any"]
      source_addresses      = ["10.1.0.0/16"]   # dev
      destination_addresses = ["10.3.0.0/16"]   # prod
      destination_ports     = ["*"]
    }

    rule {
      name                  = "deny-qa-to-prod"
      protocols             = ["Any"]
      source_addresses      = ["10.2.0.0/16"]   # qa
      destination_addresses = ["10.3.0.0/16"]   # prod
      destination_ports     = ["*"]
    }
  }

  # ── Application Rules ─────────────────────────────────────────────────────────
  # Application rules: FQDN matching (L7)
  # Evaluated AFTER network rules
  # Use for: internet egress, specific FQDN allow lists
  application_rule_collection {
    name     = "arc-allow-internet-egress"
    priority = 400
    action   = "Allow"

    # Allow Windows Update from all spokes
    rule {
      name             = "allow-windows-update"
      source_addresses = ["10.1.0.0/8"]
      destination_fqdns = [
        "*.windowsupdate.microsoft.com",
        "*.update.microsoft.com",
        "download.windowsupdate.com",
        "windowsupdate.microsoft.com",
      ]
      protocols {
        type = "Https"
        port = 443
      }
    }

    # Allow general HTTPS from dev only (not prod — prod has no internet egress)
    rule {
      name             = "allow-dev-internet-https"
      source_addresses = ["10.1.0.0/16"]   # dev only
      destination_fqdns = ["*"]             # any FQDN
      protocols {
        type = "Https"
        port = 443
      }
    }
  }
}

# ── Azure Firewall ─────────────────────────────────────────────────────────────
resource "azurerm_firewall" "hub" {
  name                = "afw-hub-lab-001"
  resource_group_name = azurerm_resource_group.hub.name
  location            = var.location
  sku_name            = "AZFW_VNet"    # VNet-injected (not vWAN)
  sku_tier            = "Standard"     # Standard for lab
  firewall_policy_id  = azurerm_firewall_policy.hub.id
  zones               = ["1", "2", "3"]

  ip_configuration {
    name                 = "fw-ipconfig"
    subnet_id            = data.azurerm_subnet.firewall.id
    public_ip_address_id = azurerm_public_ip.firewall.id
  }

  tags = local.tags
}

# ── Diagnostic settings — ship firewall logs to Log Analytics ─────────────────
# This is how you SEE what the firewall is doing
# Without this, all the traffic analysis is blind
resource "azurerm_monitor_diagnostic_setting" "firewall" {
  name                       = "diag-firewall-to-law"
  target_resource_id         = azurerm_firewall.hub.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.hub.id

  enabled_log { category = "AZFWNetworkRule" }       # L4 network rule hits
  enabled_log { category = "AZFWApplicationRule" }   # L7 app rule hits
  enabled_log { category = "AZFWThreatIntel" }       # threat intelligence hits
  enabled_log { category = "AZFWDnsProxy" }          # DNS queries through firewall

  metric { category = "AllMetrics" }
}