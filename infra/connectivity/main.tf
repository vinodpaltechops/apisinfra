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
    container_name       = "connectivity"
    key                  = "connectivity.tfstate"
  }
}

provider "azurerm" {
  features {}
  # Subscription comes from the active Azure CLI session (az account show).
}

locals {
  tags = {
    Environment = "Hub"
    ManagedBy   = "Terraform"
    Layer       = "Connectivity"
    CostCenter  = "CloudPlatform"
  }
}

# ── Resource Group ─────────────────────────────────────────────────────────────
resource "azurerm_resource_group" "hub" {
  name     = "rg-hub-connectivity-lab"
  location = var.location
  tags     = local.tags
}

# ── Hub VNet Module ────────────────────────────────────────────────────────────
module "hub_vnet" {
  source = "../modules/vnet"

  vnet_name           = "vnet-hub-lab-001"
  resource_group_name = azurerm_resource_group.hub.name
  location            = var.location
  address_space       = "10.0.0.0/16"
  tags                = local.tags

  subnets = {
    AzureFirewallSubnet = {
      address_prefix = "10.0.1.0/27"
    }
    GatewaySubnet = {
      address_prefix = "10.0.2.0/27"
    }
    AzureBastionSubnet = {
      address_prefix = "10.0.3.0/26"
    }
    snet-dns-inbound = {
      address_prefix = "10.0.4.0/28"
      delegation = {
        name                     = "Microsoft.Network.dnsResolvers"
        service_delegation_name  = "Microsoft.Network/dnsResolvers"
        actions                  = []
      }
    }
    snet-dns-outbound = {
      address_prefix = "10.0.5.0/28"
      delegation = {
        name                     = "Microsoft.Network.dnsResolvers"
        service_delegation_name  = "Microsoft.Network/dnsResolvers"
        actions                  = []
      }
    }
    snet-mgmt = {
      address_prefix = "10.0.6.0/28"
    }
  }
}

# ── NSG — simulates central firewall rules (no Azure Firewall on free tier) ───
resource "azurerm_network_security_group" "hub" {
  name                = "nsg-hub-central"
  resource_group_name = azurerm_resource_group.hub.name
  location            = var.location
  tags                = local.tags

  # Allow all internal RFC1918 traffic within hub
  security_rule {
    name                       = "allow-internal"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_address_prefix      = "10.0.0.0/8"
    destination_address_prefix = "10.0.0.0/8"
    source_port_range          = "*"
    destination_port_range     = "*"
  }

  # Allow Azure infrastructure traffic (health probes etc)
  security_rule {
    name                       = "allow-azure-infrastructure"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
  }

  # Deny everything else inbound from internet
  security_rule {
    name                       = "deny-internet-inbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
  }
}

# Associate NSG to management subnet
resource "azurerm_subnet_network_security_group_association" "mgmt" {
  subnet_id                 = module.hub_vnet.subnet_ids["snet-mgmt"]
  network_security_group_id = azurerm_network_security_group.hub.id
}

# ── Private DNS Resolver ───────────────────────────────────────────────────────
# Resolves *.privatelink.* DNS for all spokes
# Spokes point their DNS servers at this resolver's inbound IP
resource "azurerm_private_dns_resolver" "hub" {
  name                = "dnspr-hub-lab-001"
  resource_group_name = azurerm_resource_group.hub.name
  location            = var.location
  virtual_network_id  = module.hub_vnet.vnet_id
  tags                = local.tags
}

resource "azurerm_private_dns_resolver_inbound_endpoint" "hub" {
  name                    = "ep-dns-inbound"
  private_dns_resolver_id = azurerm_private_dns_resolver.hub.id
  location                = var.location

  ip_configurations {
    private_ip_allocation_method = "Dynamic"
    subnet_id                    = module.hub_vnet.subnet_ids["snet-dns-inbound"]
  }
}

resource "azurerm_private_dns_resolver_outbound_endpoint" "hub" {
  name                    = "ep-dns-outbound"
  private_dns_resolver_id = azurerm_private_dns_resolver.hub.id
  location                = var.location
  subnet_id               = module.hub_vnet.subnet_ids["snet-dns-outbound"]
}

# ── Bastion — Basic SKU (cheapest option) ─────────────────────────────────────
# Provides secure RDP/SSH to VMs across all peered spokes without public IPs
# Basic SKU: ~$0.19/hr — destroy after each session to avoid charges
resource "azurerm_public_ip" "bastion" {
  name                = "pip-bastion-lab"
  resource_group_name = azurerm_resource_group.hub.name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_bastion_host" "hub" {
  name                = "bas-hub-lab-001"
  resource_group_name = azurerm_resource_group.hub.name
  location            = var.location
  sku                 = "Standard"

  ip_configuration {
    name                 = "bastion-ipconfig"
    subnet_id            = module.hub_vnet.subnet_ids["AzureBastionSubnet"]
    public_ip_address_id = azurerm_public_ip.bastion.id
  }

  tags = local.tags
}

# ── Log Analytics Workspace ────────────────────────────────────────────────────
# Central log collection for all hub resources
# Free tier: 5GB/day ingestion, 31 day retention
resource "azurerm_log_analytics_workspace" "hub" {
  name                = "law-hub-lab-001"
  resource_group_name = azurerm_resource_group.hub.name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

# Ship NSG flow logs to Log Analytics
resource "azurerm_monitor_diagnostic_setting" "nsg_hub" {
  name                       = "diag-nsg-hub-to-law"
  target_resource_id         = azurerm_network_security_group.hub.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.hub.id

  enabled_log { category = "NetworkSecurityGroupEvent" }
  enabled_log { category = "NetworkSecurityGroupRuleCounter" }
}
