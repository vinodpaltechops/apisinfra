# MODULE: spoke-network
# One reusable spoke: resource group + VNet (4 workload subnets) + NSG + NAT
# gateway (outbound internet for non-AKS subnets).
# Subnets are derived from the /16 address_space so every environment is
# addressed consistently (dev=10.1, qa=10.2, prod=10.3):
#   snet-aks-system = x.x.1.0/24   snet-aks-user = x.x.2.0/24
#   snet-app        = x.x.3.0/24   snet-data     = x.x.4.0/24
# Peering to the hub is done by the caller (env root) so this module needs no
# provider aliases.

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
  }
}

locals {
  subnets = {
    "snet-aks-system-${var.env}" = cidrsubnet(var.address_space, 8, 1)
    "snet-aks-user-${var.env}"   = cidrsubnet(var.address_space, 8, 2)
    "snet-app-${var.env}"        = cidrsubnet(var.address_space, 8, 3)
    "snet-data-${var.env}"       = cidrsubnet(var.address_space, 8, 4)
  }
}

resource "azurerm_resource_group" "spoke" {
  name     = "rg-spoke-${var.env}-${var.org_name}-001"
  location = var.location
  tags     = var.tags
}

module "vnet" {
  source = "../vnet"

  vnet_name           = "vnet-spoke-${var.env}-001"
  resource_group_name = azurerm_resource_group.spoke.name
  location            = var.location
  address_space       = var.address_space
  dns_servers         = var.dns_servers # point at hub Private DNS Resolver inbound IP
  tags                = var.tags

  subnets = { for name, prefix in local.subnets : name => { address_prefix = prefix } }
}

# ── NSG — shared across all workload subnets in this spoke ─────────────────────
resource "azurerm_network_security_group" "spoke" {
  name                = "nsg-spoke-${var.env}"
  resource_group_name = azurerm_resource_group.spoke.name
  location            = var.location
  tags                = var.tags

  security_rule {
    name                       = "allow-from-hub"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_address_prefix      = var.hub_address_space
    destination_address_prefix = var.address_space
    source_port_range          = "*"
    destination_port_range     = "*"
  }

  security_rule {
    name                       = "allow-within-spoke"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_address_prefix      = var.address_space
    destination_address_prefix = var.address_space
    source_port_range          = "*"
    destination_port_range     = "*"
  }

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

resource "azurerm_subnet_network_security_group_association" "spoke" {
  for_each = local.subnets

  subnet_id                 = module.vnet.subnet_ids[each.key]
  network_security_group_id = azurerm_network_security_group.spoke.id
}

# ── NAT Gateway — outbound internet for the non-AKS workload subnets ──────────
# Replaces the old blackhole UDR (0.0.0.0/0 → VnetLocal). Gives the jump VM and
# other workloads a stable egress IP so cloud-init, VM extensions, etc. can
# reach the internet. The snet-aks-* subnets are intentionally NOT associated —
# AKS provides its own egress via its Standard load balancer
# (outbound_type = "loadBalancer").
#
# To move egress behind the hub Azure Firewall later: drop the NAT gateway,
# add a route table (0.0.0.0/0 → VirtualAppliance = firewall IP), and set the
# AKS module's outbound_type to "userDefinedRouting".
locals {
  nat_subnet_keys = [
    "snet-app-${var.env}",
    "snet-data-${var.env}",
  ]
}

resource "azurerm_public_ip" "nat" {
  name                = "pip-nat-spoke-${var.env}"
  resource_group_name = azurerm_resource_group.spoke.name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway" "spoke" {
  name                = "nat-spoke-${var.env}"
  resource_group_name = azurerm_resource_group.spoke.name
  location            = var.location
  sku_name            = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "spoke" {
  nat_gateway_id       = azurerm_nat_gateway.spoke.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "spoke" {
  for_each = toset(local.nat_subnet_keys)

  subnet_id      = module.vnet.subnet_ids[each.value]
  nat_gateway_id = azurerm_nat_gateway.spoke.id
}
