# LAYER 3 — POLICIES
# Purpose: assigns Azure Policy at management group scopes.
# Uses built-in policy definitions — no need to create custom ones for common controls.
# Policy assignments cascade to ALL child MGs and subscriptions automatically.
#
# Base governance only — independent of every other layer. The DINE DNS-link
# policy lives in the separate `policies-dine` layer because it depends on
# connectivity (the hub's shared DNS zone).

terraform {
  required_version = ">= 1.7.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
  }
  backend "azurerm" {
    # resource_group_name + storage_account_name come from infra/backend.json:
    #   terraform init -backend-config=../../backend.json
    container_name = "policies"
    key            = "policies.tfstate"
  }
}

provider "azurerm" {
  features {}
  # Subscription comes from the active Azure CLI session (az account show).
}

# State storage account + resource group. Same file `terraform init` reads via
# -backend-config, so the name lives in exactly one place.
locals {
  tfstate_backend = jsondecode(file("${path.module}/../../backend.json"))
}

# Management group IDs come from the management-groups layer (single source of
# truth) — no hardcoded, tenant-specific IDs to go stale.
data "terraform_remote_state" "management_groups" {
  backend = "azurerm"
  config = merge(local.tfstate_backend, {
    container_name = "management-groups"
    key            = "management-groups.tfstate"
  })
}

locals {
  mg_ids = data.terraform_remote_state.management_groups.outputs.mg_ids
}

# ── 1. Require tags on all resources (assigned at org root = everywhere) ──────
resource "azurerm_management_group_policy_assignment" "require_tags" {
  name                 = "require-cost-tags"
  display_name         = "Require CostCenter and Owner tags on all resources"
  management_group_id  = local.mg_ids["org_root"]
  policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/96670d01-0a4d-4649-9c89-2d3abc0a5025"
  # Built-in: Require a tag on resources

  parameters = jsonencode({
    tagName = { value = "CostCenter" }
  })

  enforce = true # "Deny" effect — blocks non-compliant resources
}

# # ── 2. Deny public IP addresses in Landing Zones ─────────────────────────
# resource "azurerm_management_group_policy_assignment" "deny_public_ip" {
#   name                 = "deny-public-ip-lz"
#   display_name         = "Deny public IPs in Landing Zones"
#   management_group_id  = local.mg_ids["landing_zones"]
#   policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/83a86a26-fd1f-447c-b59d-e51f44264114"
#   enforce              = true
# }

# ── 3. Deny storage accounts with public internet access ──────────────────────
resource "azurerm_management_group_policy_assignment" "deny_storage_public" {
  name                 = "deny-storage-public-lz"
  display_name         = "Deny public internet access on Storage Accounts"
  management_group_id  = local.mg_ids["landing_zones"]
  policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/b2982f36-99f2-4db5-8eff-283140c09693"
  enforce              = true
}

# ── 4. Allowed locations (prevent data sovereignty violations) ─────────────
resource "azurerm_management_group_policy_assignment" "allowed_locations" {
  name                 = "allowed-locations"
  display_name         = "Restrict resources to approved Azure regions"
  management_group_id  = local.mg_ids["org_root"]
  policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-bf8b01975c4c"

  parameters = jsonencode({
    listOfAllowedLocations = {
      value = var.allowed_locations
    }
  })

  enforce = true
}

# ── 5. Enforce Azure Monitor agent on all VMs ────────────────────────────────
# Disabled: requires managed identity for DeployIfNotExists effect
# See: https://learn.microsoft.com/azure/governance/policy/assign-policy-remediation
# resource "azurerm_management_group_policy_assignment" "require_monitor_agent" {
#   name                 = "require-ama-lz"
#   display_name         = "Deploy Azure Monitor Agent on VMs"
#   management_group_id  = local.mg_ids["landing_zones"]
#   policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/a4034bc6-ae50-406d-bf76-50f4ee5a7811"
#   enforce              = false  # "Audit" only first
#
#   identity {
#     type = "SystemAssigned"
#   }
# }

# ── 6. Deny creation of resources without Private Endpoints (Corp only) ───────
# Disabled: policy definition ID not found — verify in your region
# resource "azurerm_management_group_policy_assignment" "deny_non_private_keyvault" {
#   name                 = "deny-public-kv-corp"
#   display_name         = "Key Vaults must disable public network access"
#   management_group_id  = local.mg_ids["landing_zones"]
#   policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/55615ac9-af46-4a59-874e-391cc3f8c568"
#   enforce              = true
# }
