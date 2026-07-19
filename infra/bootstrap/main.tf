# LAYER 1 — BOOTSTRAP
# Purpose: creates the Azure Storage Account that will hold remote Terraform state
# for all subsequent layers. This is the ONLY layer whose state lives locally.
# Run this ONCE before anything else.

terraform {
  required_version = ">= 1.7.0"

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
  backend "azurerm" {
    resource_group_name  = "rg-tfstate-vinorg-001"
    storage_account_name = "stotfstatevinorgmjslia"
    container_name       = "bootstrap"
    key                  = "bootstrap.tfstate"
  }
  # Bootstrap state is LOCAL — this is intentional.
  # All other layers point their backend here.
}

provider "azurerm" {
  features {}
  # Subscription comes from the active Azure CLI session (az account show)
  # or ARM_SUBSCRIPTION_ID env var — never put subscription IDs in code.
}

# Random suffix prevents storage account name collisions (globally unique)
resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

resource "azurerm_resource_group" "tfstate" {
  name     = "rg-tfstate-${var.org_name}-001"
  location = var.location

  tags = {
    Purpose   = "Terraform remote state"
    ManagedBy = "Terraform bootstrap"
  }
  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_storage_account" "tfstate" {
  name                            = "stotfstate${var.org_name}${random_string.suffix.result}"
  resource_group_name             = azurerm_resource_group.tfstate.name
  location                        = azurerm_resource_group.tfstate.location
  account_tier                    = "Standard"
  account_replication_type        = "GRS"   # geo-redundant — state files are critical
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false   # never allow public blob access

  blob_properties {
    versioning_enabled = true               # recover from accidental state corruption
    delete_retention_policy {
      days = 30
    }
  }
  lifecycle {
    prevent_destroy = true
  }

  tags = azurerm_resource_group.tfstate.tags
}

# One container per Terraform layer — keeps state files isolated
resource "azurerm_storage_container" "layers" {
  for_each = toset([
    "bootstrap",
    "management-groups",
    "policies",
    "connectivity",
    "landing-zones-dev",
    "landing-zones-qa",
    "landing-zones-prod",
    "test-vm",
    "private-endpoints"
  ])

  name                  = each.key
  storage_account_name  = azurerm_storage_account.tfstate.name
  container_access_type = "private"

  lifecycle {
    prevent_destroy = true
  }
}
