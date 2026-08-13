variable "env" {
  type = string
}

variable "org_name" {
  type = string
}

variable "location" {
  description = "Must match the hub VNet's region — the gateway's subnet lives in that VNet."
  type        = string
}

variable "hub_resource_group_name" {
  type = string
}

variable "hub_vnet_name" {
  description = "Hub VNet that gets the dedicated App Gateway subnet."
  type        = string
}

variable "subnet_address_prefix" {
  description = "Dedicated subnet for the gateway — nothing else may share it. /24 recommended; /26 is the documented minimum for v2 and leaves no room to scale out."
  type        = string
  default     = "10.0.7.0/24"
}

variable "app_fqdn" {
  description = "Public hostname the app answers on, e.g. app.example.com. Used for the listener, the Host header sent to the backend, and the TLS certificate subject."
  type        = string
}

variable "ingress_internal_ip" {
  description = "Static private IP of the spoke's internal ingress load balancer. MUST match the azure-load-balancer-ipv4 annotation in k8s/platform/ingress-nginx-values.yaml — nothing enforces that link, so changing one without the other silently breaks the backend pool."
  type        = string
}

variable "allowed_source_prefixes" {
  description = "Source CIDRs allowed to reach ports 80/443. Defaults to the whole internet, which is the point of a public gateway; narrow it to your own IP while testing."
  type        = list(string)
  default     = ["Internet"]
}

variable "waf_mode" {
  description = "Prevention blocks malicious requests; Detection only logs them. Start in Prevention and drop to Detection only to diagnose a false positive."
  type        = string
  default     = "Prevention"

  validation {
    condition     = contains(["Prevention", "Detection"], var.waf_mode)
    error_message = "waf_mode must be Prevention or Detection."
  }
}

variable "min_capacity" {
  description = "Autoscale floor. 0 minimises lab cost but adds scale-out latency to the first request after idle; use 1+ for anything real."
  type        = number
  default     = 0
}

variable "max_capacity" {
  type    = number
  default = 2
}

variable "ssl_certificate_key_vault_secret_id" {
  description = <<-EOT
    Key Vault SECRET id of the certificate (not the certificate id) — the
    unversioned form, e.g.
    https://<vault>.vault.azure.net/secrets/<cert-name>

    null (default) = HTTP only, so the gateway can be stood up and proven
    before a certificate exists. Setting it adds an HTTPS listener and makes
    HTTP permanently redirect to it.

    Requires identity_id, and that identity needs Key Vault "Get" on both
    secrets and certificates.
  EOT
  type        = string
  default     = null
}

variable "identity_id" {
  description = "User-assigned managed identity resource ID used to read the TLS certificate from Key Vault. Required when ssl_certificate_key_vault_secret_id is set."
  type        = string
  default     = null
}

variable "tags" {
  type    = map(string)
  default = {}
}
