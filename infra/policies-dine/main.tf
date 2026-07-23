terraform {
  required_version = ">= 1.7.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
  }
}

provider "azurerm" {
  features {}
}

data "azurerm_client_config" "current" {}

variable "landing_zones_mg_id"  { type = string }
variable "dns_zone_rg_name"     { type = string }  # where private DNS zones live
variable "dns_zone_rg_id"       { type = string }
variable "subscription_id"      { type = string }

# ── Step 1: Custom Policy Definition ──────────────────────────────────────────
# Azure has no built-in DINE policy for DNS zone links
# We write our own policy rule in JSON
resource "azurerm_policy_definition" "auto_link_dns_zone_keyvault" {
  name         = "auto-link-privatelink-vault-zone"
  policy_type  = "Custom"
  mode         = "All"
  display_name = "Auto-link Key Vault private DNS zone to new VNets"
  description  = "When a VNet is created or updated, automatically create a VNet link to the Key Vault private DNS zone if one does not exist"

  # metadata tells Azure which category this appears under in portal
  metadata = jsonencode({
    category = "Network"
    version  = "1.0.0"
  })

  # Parameters the policy accepts — passed in at assignment time
  parameters = jsonencode({
    privateDnsZoneId = {
      type = "String"
      metadata = {
        displayName = "Private DNS Zone ID"
        description = "Resource ID of privatelink.vaultcore.azure.net zone"
      }
    }
    effect = {
      type = "String"
      defaultValue = "DeployIfNotExists"
      allowedValues = ["DeployIfNotExists", "Disabled"]
      metadata = {
        displayName = "Effect"
        description = "DeployIfNotExists or Disabled"
      }
    }
  })

  # The policy rule — this is the core logic
  policy_rule = jsonencode({
    if = {
      # Trigger condition: a VNet is being created or updated
      allOf = [
        {
          field  = "type"
          equals = "Microsoft.Network/virtualNetworks"
        },
        {
          # Only trigger for VNets tagged as spokes
          # This prevents the hub VNet from triggering the policy
          field  = "tags['Layer']"
          equals = "LandingZone"
        }
      ]
    }
    then = {
      effect = "[parameters('effect')]"

      details = {
        # What resource type does the remediation deploy?
        type = "Microsoft.Network/privateDnsZones/virtualNetworkLinks"

        # Where does the policy look for existing links?
        # If a link already exists, remediation is skipped
        resourceGroupName = "[resourceGroup().name]"

        # The existence condition — checks if VNet link already exists
        # If this evaluates to true, remediation is NOT triggered
        existenceCondition = {
          allOf = [
            {
              field  = "Microsoft.Network/privateDnsZones/virtualNetworkLinks/virtualNetwork.id"
              equals = "[field('id')]"
              # [field('id')] = the VNet being evaluated
            }
          ]
        }

        # The managed identity the remediation runs as
        # Must have permissions to create DNS zone links
        roleDefinitionIds = [
          "/providers/Microsoft.Authorization/roleDefinitions/b12aa53e-6015-4669-85d0-8515ebb3ae7f",
          # Private DNS Zone Contributor
          "/providers/Microsoft.Authorization/roleDefinitions/4d97b98b-1d4f-4787-a291-c67834d212e7"
          # Network Contributor
        ]

        # The ARM template that gets deployed when remediation fires
        deployment = {
          properties = {
            mode = "incremental"

            # Parameters passed into the ARM template
            parameters = {
              vnetId = {
                value = "[field('id')]"
                # The VNet resource ID being evaluated
              }
              vnetName = {
                value = "[field('name')]"
              }
              privateDnsZoneId = {
                value = "[parameters('privateDnsZoneId')]"
              }
            }

            # Inline ARM template — creates the VNet link
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
                  # This is the resource that gets deployed
                  type       = "Microsoft.Network/privateDnsZones/virtualNetworkLinks"
                  apiVersion = "2020-06-01"

                  # Name format: zoneName/linkName
                  # last() extracts the zone name from the full resource ID
                  name     = "[concat(last(split(parameters('privateDnsZoneId'), '/')), '/', parameters('vnetName'), '-link')]"
                  location = "global"
                  # DNS zone links are always "global" — not region-specific

                  properties = {
                    virtualNetwork = {
                      id = "[parameters('vnetId')]"
                    }
                    registrationEnabled = false
                    # false = zone used for resolution only
                    # true = auto-register VM DNS names (not what we want here)
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

# ── Step 2: Policy Assignment ──────────────────────────────────────────────────
# Assign the policy at Landing Zones MG scope
# Every VNet created under this MG triggers the policy

resource "azurerm_management_group_policy_assignment" "auto_link_dns_keyvault" {
  name                 = "auto-link-kv-dns"
  display_name         = "Auto-link Key Vault DNS zone to spoke VNets"
  management_group_id  = var.landing_zones_mg_id
  policy_definition_id = azurerm_policy_definition.auto_link_dns_zone_keyvault.id
  enforce              = true

  # Pass the private DNS zone ID as a parameter
  parameters = jsonencode({
    privateDnsZoneId = {
      value = "/subscriptions/${var.subscription_id}/resourceGroups/${var.dns_zone_rg_name}/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net"
    }
    effect = {
      value = "DeployIfNotExists"
    }
  })

  # CRITICAL: policy assignment needs a managed identity
  # This identity is what actually deploys the DNS zone link
  identity {
    type = "SystemAssigned"
    # Azure creates a managed identity for this policy assignment
    # We then grant RBAC roles to this identity below
  }

  location = "eastus2"
  # location required when identity block is present
}

# ── Step 3: RBAC for the policy's managed identity ────────────────────────────
# The policy's managed identity needs permissions to:
# 1. Create VNet links in the DNS zone resource group
# 2. Read VNet properties in spoke resource groups

# Private DNS Zone Contributor on the RG where DNS zones live
resource "azurerm_role_assignment" "policy_dns_contributor" {
  scope                = var.dns_zone_rg_id
  role_definition_name = "Private DNS Zone Contributor"
  principal_id         = azurerm_management_group_policy_assignment.auto_link_dns_keyvault.identity[0].principal_id

  depends_on = [azurerm_management_group_policy_assignment.auto_link_dns_keyvault]
}

# Network Contributor at subscription level
# Needed to read VNet properties across all spoke resource groups
resource "azurerm_role_assignment" "policy_network_contributor" {
  scope                = "/subscriptions/${var.subscription_id}"
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_management_group_policy_assignment.auto_link_dns_keyvault.identity[0].principal_id

  depends_on = [azurerm_management_group_policy_assignment.auto_link_dns_keyvault]
}

# ── Outputs ────────────────────────────────────────────────────────────────────
output "policy_assignment_id" {
  value = azurerm_management_group_policy_assignment.auto_link_dns_keyvault.id
}

output "policy_identity_principal_id" {
  description = "Managed identity of the policy assignment — verify its RBAC in portal"
  value       = azurerm_management_group_policy_assignment.auto_link_dns_keyvault.identity[0].principal_id
}
