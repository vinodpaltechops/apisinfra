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

output "appgw_fqdn" {
  description = "The DR gateway's hostname. This is what Traffic Manager targets: it cannot mix a hostname (the AGC endpoint) with a bare IP in one profile. appgw_public_ip stays for the A record and for debugging."
  value       = module.appgw.public_fqdn
}
