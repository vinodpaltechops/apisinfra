output "appgw_public_ip" {
  description = "DR origin address — goes into the frontdoor layer's origins map at priority 2. NOT a DNS record target: only Front Door should reach this address."
  value       = module.appgw.public_ip
}

output "appgw_name" {
  value = module.appgw.appgw_name
}

output "app_fqdn" {
  value = var.app_fqdn
}
