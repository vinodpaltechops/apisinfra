# ── Outputs needed by spoke layers ────────────────────────────────────────────
output "firewall_private_ip" {
  value       = azurerm_firewall.hub.ip_configuration[0].private_ip_address
  description = "This IP goes into all spoke UDRs as next hop"
}

output "firewall_id" {
  value = azurerm_firewall.hub.id
}