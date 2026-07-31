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
  value = module.linux_vm.vm_private_ip
}

output "vm_identity_principal_id" {
  value = module.linux_vm.vm_principal_id
}

output "ssh_command" {
  description = "SSH into the jump VM via Azure AD (run from your laptop)."
  value       = module.linux_vm.ssh_command
}

output "key_vault_uri" {
  value = module.keyvault.key_vault_uri
}

output "aks_cluster_name" {
  value = module.aks.cluster_name
}

output "aks_node_resource_group" {
  value = module.aks.node_resource_group
}

output "aks_oidc_issuer_url" {
  value = module.aks.oidc_issuer_url
}

# The private_endpoints module is currently disabled in main.tf.
# output "storage_account_name" {
#   value = module.private_endpoints.storage_account_name
# }
