# ── Outputs ────────────────────────────────────────────────────────────────────
output "vm_name"       { value = azurerm_windows_virtual_machine.test.name }
output "vm_private_ip" { value = azurerm_network_interface.vm.private_ip_address }
output "vm_id"         { value = azurerm_windows_virtual_machine.test.id }
# ADD THIS OUTPUT — needed for RBAC assignment in Key Vault layer
output "vm_identity_principal_id" {
  description = "Object ID of the VM's managed identity — used for RBAC assignments"
  value       = azurerm_windows_virtual_machine.test.identity[0].principal_id
}