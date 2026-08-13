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
  description = "Who may reach 80/443. Keep as [\"Internet\"] for a public site, or narrow to your own CIDR while testing."
  type        = list(string)
  default     = ["Internet"]
}

variable "ssl_certificate_key_vault_secret_id" {
  description = "Key Vault secret ID of the TLS cert. null = HTTP only. See docs/public-endpoint.md."
  type        = string
  default     = null
}

variable "appgw_identity_id" {
  description = "User-assigned identity resource ID that can read the cert from Key Vault. Required together with ssl_certificate_key_vault_secret_id."
  type        = string
  default     = null
}

variable "common_tags" {
  type    = map(string)
  default = {}
}
