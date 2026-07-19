# ── Outputs ────────────────────────────────────────────────────────────────────
output "storage_account_name" {
  value = azurerm_storage_account.dev.name
}

output "storage_account_id" {
  value = azurerm_storage_account.dev.id
}

output "private_endpoint_ip" {
  description = "Private IP assigned to the endpoint NIC in dev spoke"
  value       = azurerm_private_endpoint.storage_blob.private_service_connection[0].private_ip_address
}

output "storage_blob_fqdn" {
  description = "FQDN to use when connecting — should resolve to private IP"
  value       = "${azurerm_storage_account.dev.name}.blob.core.windows.net"
}

output "dns_zone_name" {
  value = azurerm_private_dns_zone.blob.name
}