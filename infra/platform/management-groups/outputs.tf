output "mg_ids" {
  description = "Map of management group name to resource ID. Used by policies layer."
  value = {
    org_root      = azurerm_management_group.org_root.id
    # platform      = azurerm_management_group.platform.id
    # connectivity  = azurerm_management_group.connectivity.id
    # identity      = azurerm_management_group.identity.id
    landing_zones = azurerm_management_group.landing_zones.id
    # corp          = azurerm_management_group.corp.id
    # online        = azurerm_management_group.online.id
    # sandbox       = azurerm_management_group.sandbox.id
  }
}
