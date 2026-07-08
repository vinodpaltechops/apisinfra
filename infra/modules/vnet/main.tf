# MODULE: vnet
# Reusable VNet + subnets. Used by both connectivity (hub) and landing-zones (spokes).
# Caller passes in address_space and a subnets map — this module creates everything.

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
  }
}

resource "azurerm_virtual_network" "this" {
  name                = var.vnet_name
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = [var.address_space]
  dns_servers         = var.dns_servers   # point spokes at Hub DNS Resolver IP
  tags                = var.tags
}

resource "azurerm_subnet" "this" {
  for_each = var.subnets

  name                 = each.key
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [each.value.address_prefix]

  # Service endpoints needed for some subnets (e.g. AKS nodes need Microsoft.ContainerRegistry)
  service_endpoints = lookup(each.value, "service_endpoints", [])

  dynamic "delegation" {
    for_each = lookup(each.value, "delegation", null) != null ? [each.value.delegation] : []
    content {
      name = delegation.value.name
      service_delegation {
        name    = delegation.value.service_delegation_name
        actions = delegation.value.actions
      }
    }
  }

  # Ignore deprecated Azure provider attributes that are auto-set by Azure
  lifecycle {
    ignore_changes = [
      enforce_private_link_endpoint_network_policies,
      enforce_private_link_service_network_policies,
      private_endpoint_network_policies_enabled,
      private_link_service_network_policies_enabled
    ]
  }
}
