output "dns_link_policy_assignment_id" {
  value = azurerm_management_group_policy_assignment.auto_link_dns_keyvault.id
}

output "dns_link_policy_identity_principal_id" {
  description = "Managed identity of the DINE policy assignment — verify its RBAC in the portal."
  value       = azurerm_management_group_policy_assignment.auto_link_dns_keyvault.identity[0].principal_id
}
