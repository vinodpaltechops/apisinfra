variable "org_name" {
  type    = string
  default = "vinorg"
}

variable "location" {
  description = "Must match the hub VNet's region."
  type        = string
  default     = "southindia"
}

variable "app_fqdn" {
  description = "Public hostname for the app, e.g. app.yourdomain.com. Set in appgw.auto.tfvars."
  type        = string
}

variable "ingress_internal_ip" {
  description = "Static private VIP of the internal ingress LB. Keep in sync with the azure-load-balancer-ipv4 annotation in k8s/platform/ingress-nginx-values.yaml."
  type        = string
  default     = "10.1.2.250"
}

variable "waf_mode" {
  type    = string
  default = "Prevention"
}

variable "allowed_source_prefixes" {
  description = "Who may reach 80/443. Keep as [\"Internet\"] for a public site, or narrow to your own CIDR while testing. Once Front Door fronts this gateway, narrow it to [\"AzureFrontDoor.Backend\"] — but only AFTER the DNS cutover, or you cut off every direct visitor."
  type        = list(string)
  default     = ["Internet"]
}

variable "frontdoor_id" {
  description = <<-EOT
    Front Door profile GUID (infra/platform/frontdoor's frontdoor_id output).

    null (default) = no WAF origin-lock rule, and this gateway stays the
    directly-reachable public entry point it is today.

    Set it after Front Door exists and the DNS cutover is done. The WAF then
    rejects requests whose X-Azure-FDID header is missing or wrong, which is
    what prevents someone reaching the origin IP directly and bypassing Front
    Door's WAF and failover. Setting it BEFORE Front Door exists blocks all
    traffic, health probes included.
  EOT
  type        = string
  default     = null
}

# ── TLS ───────────────────────────────────────────────────────────────────────

variable "enable_https" {
  description = "false (default) = HTTP only, a complete working setup needing no certificate. true = add a :443 listener; requires exactly one certificate source below."
  type        = bool
  default     = false
}

variable "http_redirect_to_https" {
  description = "Only applies when enable_https = true. true (default) makes :80 a permanent redirect to :443. false keeps :80 serving the app as well, so http:// and https:// both work — handy while testing a certificate, at the cost of the app staying reachable unencrypted."
  type        = bool
  default     = true
}

variable "ssl_certificate_key_vault_secret_id" {
  description = <<-EOT
    Unversioned Key Vault SECRET id of the certificate, e.g.
      https://kv-dev-lab-xxxx.vault.azure.net/secrets/app-tls

    The gateway fetches it at runtime, so the private key never enters
    Terraform state. Requires key_vault_id. Getting the certificate into the
    vault is manual (portal or `az keyvault certificate import`) — no Terraform
    resource can complete a CA's domain-ownership challenge.
  EOT
  type        = string
  default     = null
}

variable "key_vault_id" {
  description = "Resource ID of the vault holding the certificate. Required with ssl_certificate_key_vault_secret_id — the module grants its own managed identity Key Vault Secrets User at this scope, so no manual role assignment is needed."
  type        = string
  default     = null
}

variable "ssl_certificate_pfx_path" {
  description = "Alternative to the Key Vault source: a PFX that Terraform uploads directly. No vault or identity involved. Trade-off — the private key is stored in Terraform state."
  type        = string
  default     = null
}

variable "ssl_certificate_pfx_password" {
  description = "Password for ssl_certificate_pfx_path. Supply via TF_VAR_ssl_certificate_pfx_password, never a committed tfvars file. Use \"\" if the PFX has no password."
  type        = string
  default     = null
  sensitive   = true
}

variable "common_tags" {
  type    = map(string)
  default = {}
}
