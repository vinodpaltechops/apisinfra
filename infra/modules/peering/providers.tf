# The peering module touches two subscriptions simultaneously.
# Consumers must pass provider aliases like this:
#
# module "peering_dev" {
#   source = "../../modules/peering"
#   providers = {
#     azurerm.hub   = azurerm.connectivity
#     azurerm.spoke = azurerm.dev
#   }
#   ...
# }

terraform {
  required_providers {
    azurerm = {
      source                = "hashicorp/azurerm"
      version               = "~> 3.110"
      configuration_aliases = [azurerm.hub, azurerm.spoke]
    }
  }
}
