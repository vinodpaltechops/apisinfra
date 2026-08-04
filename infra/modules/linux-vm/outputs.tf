output "vm_name" {
  value = azurerm_linux_virtual_machine.jump.name
}

output "vm_private_ip" {
  value = azurerm_network_interface.jump.private_ip_address
}

output "vm_principal_id" {
  description = "Object ID of the VM's system-assigned managed identity — for RBAC."
  value       = azurerm_linux_virtual_machine.jump.identity[0].principal_id
}

output "vm_id" {
  value = azurerm_linux_virtual_machine.jump.id
}

output "ssh_command" {
  description = "Run from your laptop to SSH into the jump VM via Azure AD."
  value       = "az ssh vm --name ${local.vm_name} --resource-group ${var.resource_group_name}"
}
