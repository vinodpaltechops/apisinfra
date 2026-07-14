# ── Outputs ────────────────────────────────────────────────────────────────────
output "vm_name"       { value = azurerm_windows_virtual_machine.test.name }
output "vm_private_ip" { value = azurerm_network_interface.vm.private_ip_address }
output "vm_id"         { value = azurerm_windows_virtual_machine.test.id }