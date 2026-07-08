# LAYER 5 — LANDING ZONE: DEV SPOKE
# Purpose: deploys the Dev spoke VNet, peers it to the Hub, and adds
# a UDR that routes all traffic through the Hub Firewall.
# This pattern is identical for QA and Prod — only variable values differ.

terraform {
  required_version = ">= 1.7.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
  }
  backend "azurerm" {
    resource_group_name  = "rg-tfstate-vinorg-001"
    storage_account_name = "stotfstatevinorgmjslia"
    container_name       = "landing-zones-dev"
    key                  = "landing-zones-dev.tfstate"
  }
}

# Single subscription (free tier): one default provider for all spoke resources.
# Hub and spoke live in the same subscription, so the peering module gets this
# same provider for both its hub and spoke aliases. Subscription comes from
# the active Azure CLI session (az account show).
provider "azurerm" {
  features {}
}

locals {
  env   = "dev"
  tags = merge(var.common_tags, {
    Layer       = "LandingZone"
    Environment = local.env
    CostCenter  = "CloudPlatform"
  })
}

resource "azurerm_resource_group" "spoke" {
  name     = "rg-spoke-${local.env}-${var.org_name}-001"
  location = var.location
  tags     = local.tags
}

# ── Spoke VNet ────────────────────────────────────────────────────────────────
module "spoke_vnet" {
  source = "../../modules/vnet"

  vnet_name           = "vnet-spoke-${local.env}-001"
  resource_group_name = azurerm_resource_group.spoke.name
  location            = var.location
  address_space       = "10.1.0.0/16"
  # Point DNS at Hub's Private DNS Resolver inbound endpoint
  dns_servers         = [local.hub_dns_resolver_ip]
  tags                = local.tags

  subnets = {
    "snet-aks-system-${local.env}" = {
      address_prefix = "10.1.1.0/24"
    }
    "snet-aks-user-${local.env}" = {
      address_prefix = "10.1.2.0/24"
    }
    "snet-app-${local.env}" = {
      address_prefix = "10.1.3.0/24"
    }
    "snet-data-${local.env}" = {
      address_prefix = "10.1.4.0/24"
    }
  }
}

# ── NSG for spoke subnets ──────────────────────────────────────────────────────
resource "azurerm_network_security_group" "spoke" {
  name                = "nsg-spoke-${local.env}"
  resource_group_name = azurerm_resource_group.spoke.name
  location            = var.location
  tags                = local.tags

  # Allow inbound from hub (management traffic, health checks)
  security_rule {
    name                       = "allow-from-hub"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_address_prefix      = "10.0.0.0/16"   # hub range
    destination_address_prefix = "10.1.0.0/16"   # this spoke range
    source_port_range          = "*"
    destination_port_range     = "*"
  }

  # Allow inbound within this spoke (pod to pod, service to service)
  security_rule {
    name                       = "allow-within-spoke"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_address_prefix      = "10.1.0.0/16"
    destination_address_prefix = "10.1.0.0/16"
    source_port_range          = "*"
    destination_port_range     = "*"
  }

  # Allow Azure infrastructure (load balancer health probes)
  security_rule {
    name                       = "allow-azure-lb"
    priority                   = 300
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
  }

  # Deny everything else inbound
  security_rule {
    name                       = "deny-all-inbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
  }
}

# Associate NSG to all workload subnets
resource "azurerm_subnet_network_security_group_association" "aks_system" {
  subnet_id                 = module.spoke_vnet.subnet_ids["snet-aks-system-${local.env}"]
  network_security_group_id = azurerm_network_security_group.spoke.id
}

resource "azurerm_subnet_network_security_group_association" "aks_user" {
  subnet_id                 = module.spoke_vnet.subnet_ids["snet-aks-user-${local.env}"]
  network_security_group_id = azurerm_network_security_group.spoke.id
}

resource "azurerm_subnet_network_security_group_association" "app" {
  subnet_id                 = module.spoke_vnet.subnet_ids["snet-app-${local.env}"]
  network_security_group_id = azurerm_network_security_group.spoke.id
}

resource "azurerm_subnet_network_security_group_association" "data" {
  subnet_id                 = module.spoke_vnet.subnet_ids["snet-data-${local.env}"]
  network_security_group_id = azurerm_network_security_group.spoke.id
}


# ── UDR — forces all traffic through Hub Firewall ────────────────────────────
# This is the critical piece. Without this UDR, peering exists but traffic
# bypasses the firewall and goes directly between VNets.
resource "azurerm_route_table" "spoke" {
  name                       = "udr-spoke-${local.env}-001"
  resource_group_name        = azurerm_resource_group.spoke.name
  location                   = var.location
  bgp_route_propagation_enabled = false  # prevent on-prem routes from overriding
  tags                       = local.tags

  route {
    name                   = "default-to-firewall"
    address_prefix         = "0.0.0.0/0"    # ALL traffic
    next_hop_type  = "VnetLocal"
    # When you add Azure Firewall later, change to:
    # next_hop_type          = "VirtualAppliance"
    # next_hop_in_ip_address = var.hub_firewall_private_ip
  }
}

# Associate UDR to every workload subnet (not GatewaySubnet — that would break VPN)
resource "azurerm_subnet_route_table_association" "spoke" {
  for_each = toset([
    "snet-aks-system-${local.env}",
    "snet-aks-user-${local.env}",
    "snet-app-${local.env}",
    "snet-data-${local.env}"
  ])

  subnet_id      = module.spoke_vnet.subnet_ids[each.value]
  route_table_id = azurerm_route_table.spoke.id
}

# ── VNet Peering (both directions via module) ─────────────────────────────────
module "peering_dev_hub" {
  source = "../../modules/peering"

  spoke_vnet_name           = module.spoke_vnet.vnet_name
  spoke_vnet_id             = module.spoke_vnet.vnet_id
  spoke_resource_group_name = azurerm_resource_group.spoke.name
  hub_vnet_name             = local.hub_vnet_name
  hub_vnet_id               = local.hub_vnet_id
  hub_resource_group_name   = local.hub_resource_group_name
  hub_has_gateway           = false  # set true once VPN GW is deployed

  providers = {
    azurerm.hub   = azurerm
    azurerm.spoke = azurerm
  }
}

# Read outputs from connectivity layer (same backend storage)
data "terraform_remote_state" "connectivity" {
  backend = "azurerm"
  config = {
    resource_group_name  = "rg-tfstate-vinorg-001"
    storage_account_name = "stotfstatevinorgmjslia"
    container_name       = "connectivity"
    key                  = "connectivity.tfstate"
  }
}

locals {
  hub_vnet_id             = data.terraform_remote_state.connectivity.outputs.hub_vnet_id
  hub_vnet_name           = data.terraform_remote_state.connectivity.outputs.hub_vnet_name
  hub_resource_group_name = data.terraform_remote_state.connectivity.outputs.hub_rg_name
  hub_dns_resolver_ip     = data.terraform_remote_state.connectivity.outputs.dns_inbound_ip
}


# ── RBAC — Dev team gets Contributor on this subscription only ────────────────
# resource "azurerm_role_assignment" "dev_team_contributor" {
#   scope                = "/subscriptions/${var.dev_subscription_id}"
#   role_definition_name = "Contributor"
#   principal_id         = var.dev_team_group_object_id
#   provider             = azurerm.dev
# }

# # Dev team gets Reader on the Hub VNet (to view, not modify)
# resource "azurerm_role_assignment" "dev_team_hub_reader" {
#   scope                = var.hub_vnet_id
#   role_definition_name = "Reader"
#   principal_id         = var.dev_team_group_object_id
#   provider             = azurerm.connectivity
# }
