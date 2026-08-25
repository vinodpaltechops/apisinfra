output "frontdoor_id" {
  description = <<-EOT
    The profile's resource GUID. Feed this into each App Gateway layer's
    frontdoor_id so their WAFs reject requests that skipped Front Door.

    This is NOT the Terraform resource id and NOT the profile name — the
    X-Azure-FDID header carries this GUID, and a mismatch blocks all traffic.
  EOT
  value       = azurerm_cdn_frontdoor_profile.this.resource_guid
}

output "endpoint_hostname" {
  description = "The <name>.azurefd.net hostname. The CNAME target for app_fqdn. Not directly browsable, because link_to_default_domain is false."
  value       = azurerm_cdn_frontdoor_endpoint.this.host_name
}

output "custom_domain_validation_token" {
  description = "Value for the _dnsauth TXT record that proves domain ownership. Front Door will not issue the managed certificate until this record resolves."
  value       = azurerm_cdn_frontdoor_custom_domain.this.validation_token
}

output "custom_domain_validation_expires" {
  description = <<-EOT
    When the validation token above stops being accepted. Publish the _dnsauth
    TXT record before this, or the token has to be regenerated.

    azurerm 3.x does not export the domain's validation STATE, so there is no
    output for it. Check it directly:

      az afd custom-domain show -g <rg> --profile-name <profile> \
        --custom-domain-name <name> --query domainValidationState -o tsv

    It reads "Pending" until the TXT record resolves, then "Approved".
  EOT
  value       = azurerm_cdn_frontdoor_custom_domain.this.expiration_date
}

output "profile_name" {
  value = azurerm_cdn_frontdoor_profile.this.name
}

output "origin_hostnames" {
  description = "Origin host name per region label, with its failover priority — a quick check that primary really is priority 1."
  value       = { for k, o in azurerm_cdn_frontdoor_origin.this : k => "${o.host_name} (priority ${o.priority})" }
}
