output "resource_group_name" {
  value = module.spoke_network.resource_group_name
}

output "spoke_vnet_id" {
  value = module.spoke_network.vnet_id
}

output "spoke_subnet_ids" {
  value = module.spoke_network.subnet_ids
}

output "vm_private_ip" {
  value = module.test_vm.private_ip
}

output "vm_identity_principal_id" {
  value = module.test_vm.identity_principal_id
}

output "key_vault_uri" {
  value = module.keyvault.key_vault_uri
}

output "storage_account_name" {
  value = module.private_endpoints.storage_account_name
}
