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

output "public_fqdn" {
  description = "The gateway's hostname (<label>.<region>.cloudapp.azure.com). Use this, not public_ip, as a Traffic Manager target: the AGC endpoint is a hostname and a profile cannot mix the two."
  value       = azurerm_public_ip.appgw.fqdn
}
