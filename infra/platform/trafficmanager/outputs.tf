output "fqdn" {
  description = "The *.trafficmanager.net hostname — the CNAME target for app_fqdn."
  value       = module.trafficmanager.fqdn
}

output "profile_name" {
  value = module.trafficmanager.profile_name
}

output "endpoint_targets" {
  description = "Each endpoint with its failover priority — the fastest check that primary really is priority 1 and DR is 2."
  value       = module.trafficmanager.endpoint_targets
}

output "endpoint_health_command" {
  description = "Run this to see live endpoint health; Terraform cannot show it. An all-Degraded profile still answers with priority 1, so it looks healthy from a browser."
  value       = module.trafficmanager.endpoint_health_command
}

output "dns_records" {
  description = <<-EOT
    The exact DNS change required. Nothing reaches Traffic Manager until it
    exists — until then the old A record keeps serving the primary directly,
    which is why the cutover is safe to do whenever you are ready.
  EOT
  value = {
    "1_endpoint_cname" = {
      type  = "CNAME"
      name  = split(".", var.app_fqdn)[0]
      value = module.trafficmanager.fqdn
      ttl   = 600
      note  = "REPLACES the existing A record pointing at the primary App Gateway. This is the cutover — and the rollback, since restoring that A record reverts to single-region in one change. Set the registrar TTL as low as it allows; it caps how fast a rollback takes effect."
    }
  }
}

output "verify" {
  description = "Commands that prove the thing actually works, in the order worth running them."
  value = {
    "1_endpoint_health" = module.trafficmanager.endpoint_health_command
    "2_resolves_to"     = "dig +short ${module.trafficmanager.fqdn}"
    # %%{ escapes HCL's own template syntax, which would otherwise try to read
    # curl's %{http_code} as a control keyword.
    "3_serves_app" = "curl -s -o /dev/null -w '%%{http_code}\\n' -H 'Host: ${var.app_fqdn}' http://$(dig +short ${module.trafficmanager.fqdn} | tail -1)/healthz"
  }
}
