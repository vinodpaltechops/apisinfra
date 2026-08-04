# MODULE: jump-network
# A small VNet + subnet for a cross-region jump VM. Lets the jump box live in a
# DIFFERENT region's vCPU quota (e.g. centralindia) while still reaching the hub
# (and, via the hub, the spokes) over global VNet peering. DNS points at the hub
# resolver so the jump VM can resolve the centralized private DNS zones — which
# is what makes it usable once AKS/endpoints go fully private.
#
# Peering to the hub is done by the caller (env root), so no provider aliases.

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
  }
}

resource "azurerm_virtual_network" "jump" {
  name                = "vnet-jump-${var.env}-001"
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = [var.address_space]
  dns_servers         = var.dns_servers # hub Private DNS Resolver inbound IP
  tags                = var.tags
}

resource "azurerm_subnet" "jump" {
  name                 = "snet-jump-${var.env}"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.jump.name
  address_prefixes     = [cidrsubnet(var.address_space, 2, 0)] # first /26 of the /24
}

# ── NAT Gateway — outbound internet for the jump VM (cloud-init installs) ──────
resource "azurerm_public_ip" "nat" {
  name                = "pip-nat-jump-${var.env}"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway" "jump" {
  name                = "nat-jump-${var.env}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku_name            = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "jump" {
  nat_gateway_id       = azurerm_nat_gateway.jump.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "jump" {
  subnet_id      = azurerm_subnet.jump.id
  nat_gateway_id = azurerm_nat_gateway.jump.id
}
