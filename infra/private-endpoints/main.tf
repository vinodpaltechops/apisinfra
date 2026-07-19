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
    container_name       = "private-endpoints"
    key                  = "private-endpoints.tfstate"
  }
}

provider "azurerm" {
  features {
    
  }
}

locals {
  tags = {
    Environment = "Dev"
    ManagedBy   = "Terraform"
    Layer       = "PrivateEndpoint"
  }
}

# ── Storage Account ────────────────────────────────────────────────────────────
# Using random suffix because storage account names must be globally unique
resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

resource "azurerm_storage_account" "dev" {
    name = "storagepe${random_string.suffix.result}"
    resource_group_name = data.terraform_remote_state.dev.outputs.resource_group_name
    account_replication_type = "LRS"
    account_tier = "Standard"
    location = var.location
    tags = local.tags

    # Disable ALL public access — only private endpoint can reach this
    public_network_access_enabled = false
    allow_nested_items_to_be_public = false

    min_tls_version = "TLS1_2"

    network_rules {
      default_action = "Deny"
      bypass = ["AzureServices"] # allow Azure trusted services
    }
}

# ── Private Endpoint ───────────────────────────────────────────────────────────
# This is the NIC that gets deployed into your VNet
# It gets a private IP from the subnet you specify
resource "azurerm_private_endpoint" "storage_blob" {
    name                = "pe-storage-blob-dev"
    resource_group_name = data.terraform_remote_state.dev.outputs.resource_group_name
    location            = var.location
    subnet_id           = data.terraform_remote_state.dev.outputs.spoke_subnet_ids["snet-app-dev"]

    # What service does this endpoint connect to?
    private_service_connection {
        name = "psc-storage-blob-dev"
        private_connection_resource_id = azurerm_storage_account.dev.id
        is_manual_connection = false
        subresource_names = ["blob"]
    }

    # Auto-register DNS in the Private DNS Zone
    # This creates the A record automatically
    private_dns_zone_group {
        name = "pdns-storage-blob-dev"
        private_dns_zone_ids = [azurerm_private_dns_zone.blob.id]
    }

}

# ── Private DNS Zone ───────────────────────────────────────────────────────────
# One zone per service type — these zone names are fixed by Microsoft
# blob:  privatelink.blob.core.windows.net
# file:  privatelink.file.core.windows.net
# vault: privatelink.vaultcore.azure.net
# acr:   privatelink.azurecr.io
# sql:   privatelink.database.windows.net
resource "azurerm_private_dns_zone" "blob" {
    name                = "privatelink.blob.core.windows.net"
    resource_group_name = data.terraform_remote_state.dev.outputs.resource_group_name
    tags                = local.tags 
}

# ── DNS Zone VNet Links ────────────────────────────────────────────────────────
# The zone must be LINKED to a VNet for VMs in that VNet to resolve it
# Link to hub VNet — so hub DNS Resolver can answer queries from all spokes
resource "azurerm_private_dns_zone_virtual_network_link" "blob_hub" {
    name                  = "link-blob-hub"
    resource_group_name   = data.terraform_remote_state.dev.outputs.resource_group_name
    private_dns_zone_name = azurerm_private_dns_zone.blob.name
    virtual_network_id    = data.terraform_remote_state.connectivity.outputs.hub_vnet_id
    registration_enabled  = false # false = zone used for resolution only, not auto-registration
    tags = local.tags
}

# # Link to dev spoke VNet — direct resolution without going through hub resolver
# resource "azurerm_private_dns_zone_virtual_network_link" "blob_spoke_dev" {
#     name                  = "link-blob-spoke-dev"
#     resource_group_name   = data.terraform_remote_state.dev.outputs.resource_group_name
#     private_dns_zone_name = azurerm_private_dns_zone.blob.name
#     virtual_network_id    = data.terraform_remote_state.dev.outputs.spoke_vnet_id
#     registration_enabled  = false
#     tags = local.tags
# }

# define data sources to read remote state from other layers (landing-zones/dev and connectivity)
data "terraform_remote_state" "dev" {
  backend = "azurerm"
  config = {
    resource_group_name  = "rg-tfstate-vinorg-001"
    storage_account_name = "stotfstatevinorgmjslia"
    container_name       = "landing-zones-dev"
    key                  = "landing-zones-dev.tfstate"
  }
}

data "terraform_remote_state" "connectivity" {
  backend = "azurerm"
  config = {
    resource_group_name  = "rg-tfstate-vinorg-001"
    storage_account_name = "stotfstatevinorgmjslia"
    container_name       = "connectivity"
    key                  = "connectivity.tfstate"
  }
}
