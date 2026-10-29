output "key_vault_id" {
  description = "Resource ID. The landing zone builds its private endpoint against it; the gateway layers grant their identities Key Vault Secrets User on it."
  value       = module.keyvault.key_vault_id
}

output "key_vault_name" {
  value = module.keyvault.key_vault_name
}

output "key_vault_uri" {
  value = module.keyvault.key_vault_uri
}

output "resource_group_name" {
  value = azurerm_resource_group.keyvault.name
}
