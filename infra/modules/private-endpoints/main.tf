# MODULE: private-endpoints
# A storage account reachable ONLY through a private endpoint, with the
# privatelink.blob DNS zone linked to the hub so spoke VMs resolve it via the
# hub DNS Resolver.
#
# The privatelink.blob DNS zone is centralized in the hub (connectivity) layer
# and linked to the hub once; this module only registers the storage private
# endpoint into it via var.blob_private_dns_zone_id. Safe for all environments.

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

resource "azurerm_storage_account" "this" {
  name                            = "storagepe${var.env}${random_string.suffix.result}"
  resource_group_name             = var.resource_group_name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  public_network_access_enabled   = false # only the private endpoint can reach this
  allow_nested_items_to_be_public = false

  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
  }

  tags = var.tags
}

resource "azurerm_private_endpoint" "storage_blob" {
  name                = "pe-storage-blob-${var.env}"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.subnet_id

  private_service_connection {
    name                           = "psc-storage-blob-${var.env}"
    private_connection_resource_id = azurerm_storage_account.this.id
    is_manual_connection           = false
    subresource_names              = ["blob"]
  }

  private_dns_zone_group {
    name                 = "pdns-storage-blob-${var.env}"
    private_dns_zone_ids = [var.blob_private_dns_zone_id]
  }

  tags = var.tags
}
