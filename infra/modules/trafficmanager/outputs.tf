output "fqdn" {
  description = "The <name>.trafficmanager.net hostname — the CNAME target for app_fqdn. Browsable directly, but it will answer with the gateway's certificate, not one matching this name."
  value       = azurerm_traffic_manager_profile.this.fqdn
}

output "profile_name" {
  value       = azurerm_traffic_manager_profile.this.name
  description = "Profile name, for `az network traffic-manager endpoint list`."
}

output "endpoint_targets" {
  description = "Each endpoint with its failover priority — the fastest check that primary really is priority 1 and DR is 2."
  value       = { for k, e in azurerm_traffic_manager_external_endpoint.this : k => "${e.target} (priority ${e.priority})" }
}

output "endpoint_health_command" {
  description = <<-EOT
    Live endpoint health. The provider does not export monitor status, so this
    is the only way to see it — and it is the check that matters, because a
    profile whose endpoints are ALL Degraded still answers with priority 1 and
    therefore looks fine from a browser.
  EOT
  value       = "az network traffic-manager endpoint list -g ${var.resource_group_name} --profile-name ${azurerm_traffic_manager_profile.this.name} --query \"[].{name:name, priority:priority, status:endpointMonitorStatus}\" -o table"
}
