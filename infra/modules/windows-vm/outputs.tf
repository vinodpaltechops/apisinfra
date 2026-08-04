output "vm_id" {
  value = azurerm_windows_virtual_machine.this.id
}

output "vm_name" {
  value = azurerm_windows_virtual_machine.this.name
}

output "private_ip" {
  value = azurerm_network_interface.vm.private_ip_address
}

output "identity_principal_id" {
  description = "Object ID of the VM's system-assigned managed identity — for RBAC."
  value       = azurerm_windows_virtual_machine.this.identity[0].principal_id
}
