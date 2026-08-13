output "public_ip" {
  description = "Point the GoDaddy A record at this address."
  value       = azurerm_public_ip.appgw.ip_address
}

output "appgw_name" {
  value = azurerm_application_gateway.this.name
}

output "appgw_id" {
  value = azurerm_application_gateway.this.id
}

output "subnet_id" {
  value = azurerm_subnet.appgw.id
}

output "waf_policy_id" {
  value = azurerm_web_application_firewall_policy.appgw.id
}
