# MODULE: agc
# Application Gateway for Containers — the Azure-native Gateway API data plane.
# Public entry point for the workload, in the SPOKE next to the AKS cluster:
#
#   internet → DNS CNAME → AGC frontend FQDN
#            → AGC data plane (Azure-managed, injected into snet-agc)
#            → pod IPs directly (frontend :8080, backend :8000)
#
# This module is the Azure half. The cluster half is the ALB Controller (Helm,
# installed through Argo CD) plus Gateway / HTTPRoute manifests; the controller
# uses the identity created here to program this resource.
#
# Lives in the spoke, not the hub, because the data plane must sit in the
# cluster's own VNet: the AKS overlay pod CIDR is not routable over peering, so
# a hub-side gateway could never reach the pods. Application Gateway for
# Containers is also only offered in some regions (centralindia yes, southindia
# no), which is why the dev spoke moved.
#
# azurerm 3.x has no resource for Microsoft.ServiceNetworking, so the three AGC
# resources go through azapi. Everything else is plain azurerm.

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
  }
}

locals {
  name = "agc-${var.env}-${var.org_name}-001"

  # See the matching note in the appgw module: a service tag is only legal in
  # the singular source_address_prefix field, a CIDR list only in the plural one.
  web_source_tag = (
    length(var.allowed_source_prefixes) == 1 &&
    !can(cidrhost(var.allowed_source_prefixes[0], 0))
  ) ? var.allowed_source_prefixes[0] : null
}

# ── Resource group — AGC and its identity get their own ───────────────────────
# Separate from the spoke RG so the role assignments below can be scoped to
# exactly this, and so tearing the gateway down never touches the cluster.
resource "azurerm_resource_group" "agc" {
  name     = "rg-agc-${var.env}-${var.org_name}-001"
  location = var.location
  tags     = var.tags
}

# ── Subnet — dedicated, delegated, in the cluster's VNet ──────────────────────
# Standalone azurerm_subnet on the existing spoke VNet, same approach as the
# appgw module: the vnet module declares its subnets as separate resources, not
# inline blocks, so an extra one here is not deleted by the landing zone.
#
# AGC needs at least a /24. The delegation is what lets the service inject its
# data plane into the subnet.
resource "azurerm_subnet" "agc" {
  name                 = "snet-agc-${var.env}"
  resource_group_name  = var.vnet_resource_group_name
  virtual_network_name = var.vnet_name
  address_prefixes     = [var.subnet_address_prefix]

  delegation {
    name = "agc"
    service_delegation {
      name    = "Microsoft.ServiceNetworking/trafficControllers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# The spoke NSG is not attached to this subnet (it only covers the four AKS/app/
# data subnets), so the gateway gets its own. Traffic from here INTO the cluster
# is already allowed by the spoke NSG's allow-within-spoke and
# allow-spoke-to-aks-pods rules, since snet-agc is inside the spoke range.
resource "azurerm_network_security_group" "agc" {
  name                = "nsg-${local.name}"
  resource_group_name = azurerm_resource_group.agc.name
  location            = var.location
  tags                = var.tags

  security_rule {
    name                       = "allow-azure-lb"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_address_prefix      = "AzureLoadBalancer"
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_range     = "*"
  }

  # The public traffic. Narrow allowed_source_prefixes to your own IP while
  # testing. Exactly one of the two source fields is set — see web_source_tag.
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

resource "azurerm_subnet_network_security_group_association" "agc" {
  subnet_id                 = azurerm_subnet.agc.id
  network_security_group_id = azurerm_network_security_group.agc.id
}

# ── The gateway: traffic controller + frontend + subnet association ───────────
resource "azapi_resource" "agc" {
  type      = "Microsoft.ServiceNetworking/trafficControllers@2023-11-01"
  name      = local.name
  parent_id = azurerm_resource_group.agc.id
  location  = var.location
  tags      = var.tags

  body = {}
}

# The frontend is the public entry point. Azure generates its FQDN
# (<random>.<zone>.alb.azure.com); there is no IP to point an A record at, so
# the DNS record for the app is a CNAME to this name.
resource "azapi_resource" "frontend" {
  type      = "Microsoft.ServiceNetworking/trafficControllers/frontends@2023-11-01"
  name      = "fe-${var.env}"
  parent_id = azapi_resource.agc.id
  location  = var.location
  tags      = var.tags

  body = {}

  response_export_values = ["properties.fqdn"]
}

resource "azapi_resource" "association" {
  type      = "Microsoft.ServiceNetworking/trafficControllers/associations@2023-11-01"
  name      = "assoc-${var.env}"
  parent_id = azapi_resource.agc.id
  location  = var.location
  tags      = var.tags

  body = {
    properties = {
      associationType = "subnets"
      subnet          = { id = azurerm_subnet.agc.id }
    }
  }

  # The NSG must be on the subnet before the service populates it, otherwise the
  # data plane comes up with Azure's default rules for a moment.
  depends_on = [azurerm_subnet_network_security_group_association.agc]
}

# ── ALB Controller identity (workload identity) ───────────────────────────────
# The in-cluster ALB Controller reads Gateway / HTTPRoute objects and writes the
# equivalent config into the AGC resource above. It authenticates as this
# identity through a federated credential on its service account — no secret.
resource "azurerm_user_assigned_identity" "alb" {
  name                = "id-alb-controller-${var.env}"
  resource_group_name = azurerm_resource_group.agc.name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "alb" {
  name                = "fic-alb-controller-${var.env}"
  resource_group_name = azurerm_resource_group.agc.name
  parent_id           = azurerm_user_assigned_identity.alb.id
  issuer              = var.aks_oidc_issuer_url
  subject             = "system:serviceaccount:${var.alb_namespace}:${var.alb_service_account}"
  audience            = ["api://AzureADTokenExchange"]
}

data "azurerm_resource_group" "aks_nodes" {
  name = var.aks_node_resource_group_name
}

# Configuration Manager on the AGC resource group is the permission to create and
# change gateway configuration; the group holds only this gateway, so the scope
# is as tight as the role allows.
resource "azurerm_role_assignment" "alb_config_manager" {
  scope                = azurerm_resource_group.agc.id
  role_definition_name = "AppGw for Containers Configuration Manager"
  principal_id         = azurerm_user_assigned_identity.alb.principal_id
}

# Lets the controller join the gateway's network interfaces to the delegated
# subnet while it reconciles the association.
resource "azurerm_role_assignment" "alb_subnet_join" {
  scope                = azurerm_subnet.agc.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.alb.principal_id
}

# Read access to the cluster's node resource group, as in Microsoft's install
# guide, so the controller can resolve the cluster's network.
resource "azurerm_role_assignment" "alb_nodes_reader" {
  scope                = data.azurerm_resource_group.aks_nodes.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.alb.principal_id
}
