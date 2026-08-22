variable "org_name" {
  type    = string
  default = "vinorg"
}

variable "app_fqdn" {
  description = "Same hostname the primary gateway serves. Both regions answer for one name; Front Door decides which one is live."
  type        = string
}

variable "subnet_address_prefix" {
  description = "Dedicated /24 for the gateway inside the DR spoke (10.5.0.0/16). Must not overlap the spoke's snet-* subnets, which occupy 10.5.1.0/24 through 10.5.4.0/24."
  type        = string
  default     = "10.5.7.0/24"
}

variable "waf_mode" {
  type    = string
  default = "Prevention"
}

variable "allowed_source_prefixes" {
  description = "Keep as [\"AzureFrontDoor.Backend\"]. Widening this to [\"Internet\"] makes the DR gateway independently reachable, which bypasses Front Door's routing and failover logic entirely."
  type        = list(string)
  default     = ["AzureFrontDoor.Backend"]
}

variable "frontdoor_id" {
  description = "Front Door profile GUID (the frontdoor layer's frontdoor_id output). Leave null on the FIRST apply — Front Door does not exist yet, and setting it early blocks even its health probes. See the two-pass note in main.tf."
  type        = string
  default     = null
}

variable "enable_https" {
  type    = bool
  default = true
}

variable "http_redirect_to_https" {
  description = "false keeps :80 serving the app as well. Front Door reaches origins on 443 (forwarding_protocol = HttpsOnly), so a redirect on :80 is never exercised — but leaving :80 functional is what allows a direct-to-origin curl when debugging a failover."
  type        = bool
  default     = false
}

variable "ssl_certificate_key_vault_secret_id" {
  description = "UNVERSIONED Key Vault secret URL of the certificate — the SAME one the primary gateway uses. Unversioned so both gateways follow a rotation without a Terraform change."
  type        = string
  default     = null
}

variable "key_vault_id" {
  description = "Resource ID of the dev spoke's vault. The module grants this gateway's own identity Key Vault Secrets User at this scope — separate from the primary gateway's assignment, so the two never collide."
  type        = string
  default     = null
}

variable "common_tags" {
  type    = map(string)
  default = {}
}
