output "frontdoor_id" {
  description = <<-EOT
    Profile GUID. Set this as frontdoor_id in BOTH appgw layers' tfvars and
    re-apply them — that is what makes each gateway's WAF reject requests that
    reached it without going through Front Door.

    Until you do, both gateway public IPs remain independently reachable and
    Front Door's WAF, routing and failover can all be skipped by anyone who
    finds them.
  EOT
  value       = module.frontdoor.frontdoor_id
}

output "endpoint_hostname" {
  description = "The *.azurefd.net endpoint — the CNAME target for app_fqdn."
  value       = module.frontdoor.endpoint_hostname
}

output "custom_domain_validation_expires" {
  description = "Deadline for publishing the _dnsauth TXT record — after it, the validation token must be regenerated. The provider does not expose the validation STATE; the module output explains the `az afd custom-domain show` command that does."
  value       = module.frontdoor.custom_domain_validation_expires
}

output "origin_hostnames" {
  description = "Each origin with its failover priority — the fastest check that primary really is priority 1 and DR is 2."
  value       = module.frontdoor.origin_hostnames
}

output "dns_records" {
  description = <<-EOT
    The exact DNS changes required, IN ORDER. Nothing is served on app_fqdn
    until both exist.
  EOT
  value = {
    "1_validation_txt" = {
      type  = "TXT"
      name  = "_dnsauth.${split(".", var.app_fqdn)[0]}"
      value = module.frontdoor.custom_domain_validation_token
      ttl   = 3600
      note  = "Proves domain ownership. Front Door will not issue the managed certificate until this resolves. Create it FIRST and wait for custom_domain_state to reach 'Approved'."
    }
    "2_endpoint_cname" = {
      type  = "CNAME"
      name  = split(".", var.app_fqdn)[0]
      value = module.frontdoor.endpoint_hostname
      ttl   = 600
      note  = "REPLACES the existing A record that points at the primary App Gateway. This is the cutover — and the rollback, since restoring that A record reverts to single-region in one change."
    }
  }
}
