output "zone_name" {
  value = azurerm_dns_zone.this.name
}

output "name_servers" {
  description = "The four nameservers to enter at the registrar."
  value       = azurerm_dns_zone.this.name_servers
}

output "app_record" {
  description = "What app_fqdn resolves to once the zone is live."
  value       = "${var.app_fqdn} CNAME ${azurerm_dns_cname_record.app.record}"
}

output "delegation" {
  description = "The registrar change, in order. Nothing is live until step 4."
  value = {
    "1_compare"   = "Diff the OLD zone against this one: dig +short @ns21.domaincontrol.com ${var.zone_name} ANY. Anything missing here stops resolving after step 4."
    "2_check_new" = "dig +short @${sort(tolist(azurerm_dns_zone.this.name_servers))[0]} ${var.app_fqdn} CNAME"
    "3_lower_ttl" = "At GoDaddy, lower the NS record TTL a day beforehand so a rollback is quick."
    "4_delegate"  = "GoDaddy > Domain > DNS > Nameservers > Change > Enter my own nameservers > ${join(", ", azurerm_dns_zone.this.name_servers)}"
    "5_verify"    = "dig NS ${var.zone_name} +short ; dig ${var.app_fqdn} +short"
    "rollback"    = "Set the nameservers at GoDaddy back to the default (ns21/ns22.domaincontrol.com)."
  }
}
