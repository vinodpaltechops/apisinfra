# LAYER 2 — MANAGEMENT GROUPS
# Purpose: builds the full CAF management group hierarchy and associates
# subscriptions. This defines the governance skeleton everything else attaches to.

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
  }

  backend "azurerm" {
    resource_group_name  = "rg-tfstate-vinorg-001"   # from bootstrap output
    storage_account_name = "stotfstatevinorgmjslia"   # fill from bootstrap output
    container_name       = "management-groups"
    key                  = "management-groups.tfstate"
  }
}

provider "azurerm" {
  features {}
  # Subscription comes from the active Azure CLI session (az account show).
  # That identity needs "Management Group Contributor" at tenant root scope.
}

# ── Management Group Hierarchy ───────────────────────────────────────────────

# Level 1 — Org root (sits directly under the Azure tenant root MG)
resource "azurerm_management_group" "org_root" {
  display_name = var.org_name
  # parent_management_group_id omitted = parented to tenant root automatically
}

# # Level 2 — Platform branch (infra owned by the cloud platform team)
# resource "azurerm_management_group" "platform" {
#   display_name               = "Platform"
#   parent_management_group_id = azurerm_management_group.org_root.id
# }

# resource "azurerm_management_group" "connectivity" {
#   display_name               = "Connectivity"
#   parent_management_group_id = azurerm_management_group.platform.id
# }

# resource "azurerm_management_group" "identity" {
#   display_name               = "Identity"
#   parent_management_group_id = azurerm_management_group.platform.id
# }

# resource "azurerm_management_group" "management" {
#   display_name               = "Management"
#   parent_management_group_id = azurerm_management_group.platform.id
# }

# Level 2 — Landing Zones branch (workload subscriptions live here)
resource "azurerm_management_group" "landing_zones" {
  display_name               = "LandingZones"
  parent_management_group_id = azurerm_management_group.org_root.id
}

# resource "azurerm_management_group" "corp" {
#   display_name               = "Corp"
#   parent_management_group_id = azurerm_management_group.landing_zones.id
# }

# resource "azurerm_management_group" "online" {
#   display_name               = "Online"
#   parent_management_group_id = azurerm_management_group.landing_zones.id
# }

# # Level 2 — Sandbox (no policies — free experimentation zone for engineers)
# resource "azurerm_management_group" "sandbox" {
#   display_name               = "Sandbox"
#   parent_management_group_id = azurerm_management_group.org_root.id
# }

# ── Subscription Associations ────────────────────────────────────────────────
# Associates pre-existing subscriptions to the right MG.
# Subscriptions must already exist — Terraform doesn't create subscriptions
# in most enterprise setups (EA/MCA billing creates them).

resource "azurerm_management_group_subscription_association" "landing_zones" {
  management_group_id = azurerm_management_group.landing_zones.id
  subscription_id     = "/subscriptions/${var.subscription_ids["landing_zones"]}"

  lifecycle {
    prevent_destroy = true
  }
}

# resource "azurerm_management_group_subscription_association" "connectivity" {
#   management_group_id = azurerm_management_group.connectivity.id
#   subscription_id     = "/subscriptions/${var.subscription_ids["connectivity"]}"
# }

# resource "azurerm_management_group_subscription_association" "identity" {
#   management_group_id = azurerm_management_group.identity.id
#   subscription_id     = "/subscriptions/${var.subscription_ids["identity"]}"
# }

# resource "azurerm_management_group_subscription_association" "dev" {
#   management_group_id = azurerm_management_group.corp.id
#   subscription_id     = "/subscriptions/${var.subscription_ids["dev"]}"
# }

# resource "azurerm_management_group_subscription_association" "qa" {
#   management_group_id = azurerm_management_group.corp.id
#   subscription_id     = "/subscriptions/${var.subscription_ids["qa"]}"
# }

# resource "azurerm_management_group_subscription_association" "prod" {
#   management_group_id = azurerm_management_group.corp.id
#   subscription_id     = "/subscriptions/${var.subscription_ids["prod"]}"
# }
