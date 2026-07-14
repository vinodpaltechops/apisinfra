output "spoke_vnet_id"   { value = module.spoke_vnet.vnet_id }
output "spoke_vnet_name" { value = module.spoke_vnet.vnet_name }
output "spoke_subnet_ids" { value = module.spoke_vnet.subnet_ids }
output "resource_group_name" { value = azurerm_resource_group.spoke.name }
