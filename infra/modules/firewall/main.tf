# MODULE: firewall
# Deploys Azure Firewall Premium + Firewall Policy.
# Firewall Policy is the modern way — rules live in the policy, not inline.
# Policy can be shared across multiple firewalls (useful in multi-region setups).

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
  }
}

resource "azurerm_public_ip" "firewall" {
  name                = "${var.firewall_name}-pip"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"   # Standard SKU required for Azure Firewall
  zones               = var.availability_zones
  tags                = var.tags
}

resource "azurerm_firewall_policy" "this" {
  name                = "${var.firewall_name}-policy"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Premium"   # Premium: IDPS, TLS inspection, URL filtering

  # DNS proxy: Firewall acts as DNS forwarder for all spoke VMs
  # When enabled, all DNS queries from VMs go through Firewall → DNS Resolver
  dns {
    proxy_enabled = true
    servers       = var.dns_resolver_ips
  }

  threat_intelligence_mode = "Alert"   # start with Alert, move to Deny after tuning
  tags                     = var.tags
}

resource "azurerm_firewall" "this" {
  name                = var.firewall_name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku_name            = "AZFW_VNet"   # VNet-injected (not vWAN)
  sku_tier            = "Premium"
  firewall_policy_id  = azurerm_firewall_policy.this.id
  zones               = var.availability_zones

  ip_configuration {
    name                 = "fw-ipconfig"
    subnet_id            = var.firewall_subnet_id   # must be named AzureFirewallSubnet
    public_ip_address_id = azurerm_public_ip.firewall.id
  }

  tags = var.tags
}

# ── Firewall Policy Rule Collections ─────────────────────────────────────────

resource "azurerm_firewall_policy_rule_collection_group" "core" {
  name               = "rcg-core"
  firewall_policy_id = azurerm_firewall_policy.this.id
  priority           = 100   # lower number = evaluated first

  # Network rules: IP/port level (faster than app rules)
  network_rule_collection {
    name     = "allow-azure-services"
    priority = 100
    action   = "Allow"

    rule {
      name                  = "allow-azure-monitor"
      protocols             = ["TCP"]
      source_addresses      = ["10.0.0.0/8"]    # all internal RFC1918
      destination_addresses = ["AzureMonitor"]   # service tag
      destination_ports     = ["443"]
    }

    rule {
      name                  = "allow-key-vault"
      protocols             = ["TCP"]
      source_addresses      = ["10.0.0.0/8"]
      destination_addresses = ["AzureKeyVault"]
      destination_ports     = ["443"]
    }

    rule {
      name                  = "allow-acr"
      protocols             = ["TCP"]
      source_addresses      = ["10.0.0.0/8"]
      destination_addresses = ["AzureContainerRegistry"]
      destination_ports     = ["443"]
    }

    rule {
      name                  = "allow-spoke-to-spoke"
      protocols             = ["Any"]
      source_addresses      = ["10.1.0.0/8"]    # all spoke ranges
      destination_addresses = ["10.1.0.0/8"]
      destination_ports     = ["*"]
      # All spoke-to-spoke traffic must transit the firewall
      # This is enforced by UDRs in each spoke subnet
    }
  }

  # Application rules: FQDN-level (TLS inspection available with Premium)
  application_rule_collection {
    name     = "allow-windows-update"
    priority = 200
    action   = "Allow"

    rule {
      name              = "windows-update"
      source_addresses  = ["10.0.0.0/8"]
      destination_fqdns = [
        "*.windowsupdate.microsoft.com",
        "*.update.microsoft.com",
        "download.windowsupdate.com",
      ]
      protocols {
        type = "Https"
        port = 443
      }
    }
  }
}
