# LAYER: POLICIES — DINE (DeployIfNotExists)
# A custom DINE policy that auto-links spoke VNets to the centralized Key Vault
# private DNS zone. Kept SEPARATE from the base `policies` layer because it
# depends on the connectivity layer (which owns the shared DNS zone): base
# governance stays deployable before connectivity, this one is applied after.
#
# Deploy order: management-groups → connectivity → policies-dine

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
    storage_account_name = "stotfstatevinorg001"
    container_name       = "policies-dine"
    key                  = "policies-dine.tfstate"
  }
}

provider "azurerm" {
  features {}
  skip_provider_registration = true
}

data "azurerm_subscription" "current" {}

# Shared vault DNS zone + hub RG come from the connectivity layer's outputs.
data "terraform_remote_state" "connectivity" {
  backend = "azurerm"
  config = {
    resource_group_name  = "rg-tfstate-vinorg-001"
    storage_account_name = "stotfstatevinorg001"
    container_name       = "connectivity"
    key                  = "connectivity.tfstate"
  }
}

# Landing Zones MG id comes from the management-groups layer (no stale IDs).
data "terraform_remote_state" "management_groups" {
  backend = "azurerm"
  config = {
    resource_group_name  = "rg-tfstate-vinorg-001"
    storage_account_name = "stotfstatevinorg001"
    container_name       = "management-groups"
    key                  = "management-groups.tfstate"
  }
}

locals {
  subscription_id     = data.azurerm_subscription.current.subscription_id
  landing_zones_mg_id = data.terraform_remote_state.management_groups.outputs.mg_ids["landing_zones"]
  hub_rg_id           = "/subscriptions/${data.azurerm_subscription.current.subscription_id}/resourceGroups/${data.terraform_remote_state.connectivity.outputs.hub_rg_name}"
  vault_dns_zone_id   = data.terraform_remote_state.connectivity.outputs.vault_private_dns_zone_id
}

# ── Custom DINE policy definition ─────────────────────────────────────────────
# Azure has no built-in DINE policy for private DNS zone links, so we define one.
resource "azurerm_policy_definition" "auto_link_dns_zone_keyvault" {
  name         = "auto-link-privatelink-vault-zone"
  policy_type  = "Custom"
  mode         = "All"
  display_name = "Auto-link Key Vault private DNS zone to new VNets"
  description  = "When a VNet is created or updated, automatically create a VNet link to the Key Vault private DNS zone if one does not exist"

  metadata = jsonencode({
    category = "Network"
    version  = "1.0.0"
  })

  parameters = jsonencode({
    privateDnsZoneId = {
      type = "String"
      metadata = {
        displayName = "Private DNS Zone ID"
        description = "Resource ID of privatelink.vaultcore.azure.net zone"
      }
    }
    effect = {
      type          = "String"
      defaultValue  = "DeployIfNotExists"
      allowedValues = ["DeployIfNotExists", "Disabled"]
      metadata = {
        displayName = "Effect"
        description = "DeployIfNotExists or Disabled"
      }
    }
  })

  policy_rule = jsonencode({
    if = {
      allOf = [
        {
          field  = "type"
          equals = "Microsoft.Network/virtualNetworks"
        },
        {
          field  = "tags['Layer']"
          equals = "LandingZone"
        }
      ]
    }
    then = {
      effect = "[parameters('effect')]"
      details = {
        type              = "Microsoft.Network/privateDnsZones/virtualNetworkLinks"
        resourceGroupName = "[resourceGroup().name]"
        existenceCondition = {
          allOf = [
            {
              field  = "Microsoft.Network/privateDnsZones/virtualNetworkLinks/virtualNetwork.id"
              equals = "[field('id')]"
            }
          ]
        }
        roleDefinitionIds = [
          "/providers/Microsoft.Authorization/roleDefinitions/b12aa53e-6015-4669-85d0-8515ebb3ae7f",
          "/providers/Microsoft.Authorization/roleDefinitions/4d97b98b-1d4f-4787-a291-c67834d212e7"
        ]
        deployment = {
          properties = {
            mode = "incremental"
            parameters = {
              vnetId = {
                value = "[field('id')]"
              }
              vnetName = {
                value = "[field('name')]"
              }
              privateDnsZoneId = {
                value = "[parameters('privateDnsZoneId')]"
              }
            }
            template = {
              "$schema"      = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
              contentVersion = "1.0.0.0"
              parameters = {
                vnetId = {
                  type = "string"
                }
                vnetName = {
                  type = "string"
                }
                privateDnsZoneId = {
                  type = "string"
                }
              }
              resources = [
                {
                  type       = "Microsoft.Network/privateDnsZones/virtualNetworkLinks"
                  apiVersion = "2020-06-01"
                  name       = "[concat(last(split(parameters('privateDnsZoneId'), '/')), '/', parameters('vnetName'), '-link')]"
                  location   = "global"
                  properties = {
                    virtualNetwork = {
                      id = "[parameters('vnetId')]"
                    }
                    registrationEnabled = false
                  }
                }
              ]
            }
          }
        }
      }
    }
  })
}

# ── Assignment at the Landing Zones MG ────────────────────────────────────────
resource "azurerm_management_group_policy_assignment" "auto_link_dns_keyvault" {
  name                 = "auto-link-kv-dns"
  display_name         = "Auto-link Key Vault DNS zone to spoke VNets"
  management_group_id  = local.landing_zones_mg_id
  policy_definition_id = azurerm_policy_definition.auto_link_dns_zone_keyvault.id
  enforce              = true

  parameters = jsonencode({
    privateDnsZoneId = {
      value = local.vault_dns_zone_id
    }
    effect = {
      value = "DeployIfNotExists"
    }
  })

  identity {
    type = "SystemAssigned"
  }

  location = var.location # required when an identity block is present
}

# ── RBAC for the policy's managed identity ────────────────────────────────────
# Private DNS Zone Contributor on the hub RG (where the shared zones live)
resource "azurerm_role_assignment" "policy_dns_contributor" {
  scope                = local.hub_rg_id
  role_definition_name = "Private DNS Zone Contributor"
  principal_id         = azurerm_management_group_policy_assignment.auto_link_dns_keyvault.identity[0].principal_id

  depends_on = [azurerm_management_group_policy_assignment.auto_link_dns_keyvault]
}

# Network Contributor at subscription scope (read VNet properties across spokes)
resource "azurerm_role_assignment" "policy_network_contributor" {
  scope                = "/subscriptions/${local.subscription_id}"
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_management_group_policy_assignment.auto_link_dns_keyvault.identity[0].principal_id

  depends_on = [azurerm_management_group_policy_assignment.auto_link_dns_keyvault]
}
