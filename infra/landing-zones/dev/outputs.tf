output "resource_group_name" {
  value = module.spoke_network.resource_group_name
}

output "spoke_vnet_id" {
  value = module.spoke_network.vnet_id
}

output "spoke_subnet_ids" {
  value = module.spoke_network.subnet_ids
}

# Jump-VM outputs — disabled together with module "linux_vm" in main.tf.
# Re-enable both at once; a commented-out module leaves these dangling and
# `terraform validate` fails with "Reference to undeclared module".
# output "vm_private_ip" {
#   value = module.linux_vm.vm_private_ip
# }
#
# output "vm_identity_principal_id" {
#   value = module.linux_vm.vm_principal_id
# }
#
# output "ssh_command" {
#   description = "SSH into the jump VM via Azure AD (run from your laptop)."
#   value       = module.linux_vm.ssh_command
# }

# Mgmt-VM outputs — disabled together with module "linux_vm_mgmt" in main.tf.
# output "mgmt_vm_public_ip" {
#   description = "Public IP of the mgmt/bastion-replacement VM — SSH here as azureadmin."
#   value       = module.linux_vm_mgmt.public_ip
# }
#
# output "mgmt_vm_identity_principal_id" {
#   description = "Managed identity of the mgmt VM — holds Key Vault Secrets User and, via the aks module, cluster admin."
#   value       = module.linux_vm_mgmt.vm_principal_id
# }

output "key_vault_id" {
  description = "Resource ID of the vault (platform/keyvault, re-exported so the gateway layers keep reading it from here). They use it to grant their identities Key Vault Secrets User."
  value       = data.terraform_remote_state.keyvault.outputs.key_vault_id
}

output "key_vault_uri" {
  value = data.terraform_remote_state.keyvault.outputs.key_vault_uri
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

output "acr_name" {
  description = "Short registry name — used by the app pipeline for `az acr login`."
  value       = module.acr.registry_name
}

output "acr_login_server" {
  description = "Image prefix for the k8s manifests, e.g. acrdevvinorg001.azurecr.io."
  value       = module.acr.login_server
}

# The private_endpoints module is currently disabled in main.tf.
# output "storage_account_name" {
#   value = module.private_endpoints.storage_account_name
# }
