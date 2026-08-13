output "appgw_public_ip" {
  description = "Create the GoDaddy A record for app_fqdn pointing at this address."
  value       = module.appgw.public_ip
}

output "app_fqdn" {
  value = var.app_fqdn
}

output "appgw_name" {
  value = module.appgw.appgw_name
}

output "dns_record_instructions" {
  description = "Exactly what to enter in GoDaddy's DNS management page."
  value       = "GoDaddy → DNS → Add record: Type=A, Name=${split(".", var.app_fqdn)[0]}, Value=${module.appgw.public_ip}, TTL=600"
}
