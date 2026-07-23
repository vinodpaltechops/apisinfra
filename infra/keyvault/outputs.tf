# ── Outputs ────────────────────────────────────────────────────────────────────
output "key_vault_name"  { value = azurerm_key_vault.dev.name }
output "key_vault_uri"   { value = azurerm_key_vault.dev.vault_uri }
output "key_vault_id"    { value = azurerm_key_vault.dev.id }
output "kv_private_ip" {
  value = azurerm_private_endpoint.keyvault.private_service_connection[0].private_ip_address
}