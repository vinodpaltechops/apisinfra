output "resource_group_name" {
  value = azurerm_resource_group.spoke.name
}

output "vnet_id" {
  value = module.vnet.vnet_id
}

output "vnet_name" {
  value = module.vnet.vnet_name
}

output "subnet_ids" {
  description = "Map of subnet name → id for all workload subnets."
  value       = module.vnet.subnet_ids
}

output "app_subnet_id" {
  description = "snet-app subnet — used by the test VM NIC and storage private endpoint."
  value       = module.vnet.subnet_ids["snet-app-${var.env}"]
}

output "data_subnet_id" {
  description = "snet-data subnet — used by the Key Vault private endpoint."
  value       = module.vnet.subnet_ids["snet-data-${var.env}"]
}
