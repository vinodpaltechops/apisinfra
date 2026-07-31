output "storage_account_name" {
  description = "Name of the storage account holding all remote state."
  value       = azurerm_storage_account.tfstate.name
}

output "resource_group_name" {
  description = "Resource group containing the state storage account."
  value       = azurerm_resource_group.tfstate.name
}

output "storage_account_id" {
  value = azurerm_storage_account.tfstate.id
}
