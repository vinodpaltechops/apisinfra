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
  description = <<-EOT
    Who may reach ports 80/443.

    Either a single service tag — ["Internet"] (default), which is the point of
    a public gateway — or a list of real CIDRs, e.g. ["163.223.165.0/24"], to
    keep it private while testing. Do not mix the two: Azure accepts a service
    tag only in the singular source_address_prefix field, so a list containing
    both a tag and a CIDR cannot be expressed and will be rejected at apply
    time. The module picks the correct field for you.
  EOT
  type        = list(string)
  default     = ["Internet"]

  validation {
    condition = (
      length(var.allowed_source_prefixes) == 1 ||
      alltrue([for p in var.allowed_source_prefixes : can(cidrhost(p, 0))])
    )
    error_message = "Use either a single service tag (e.g. [\"Internet\"]) or a list of valid CIDRs — not a mixture."
  }
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

variable "ssl_policy_name" {
  description = <<-EOT
    Predefined TLS policy for the gateway. Must be set — Azure's implicit
    default (AppGwSslPolicy20150501) allows TLS 1.0/1.1 and is now rejected
    outright with ApplicationGatewayDeprecatedTlsVersionUsedInSslPolicy.

    Only two current options enforce a TLS 1.2 floor:
      AppGwSslPolicy20220101   broad cipher set  (default — widest client support)
      AppGwSslPolicy20220101S  stricter ciphers, ECDHE/AEAD only

    Every current browser works with either. Prefer the S variant unless you
    have a client that fails the handshake.
  EOT
  type        = string
  default     = "AppGwSslPolicy20220101"

  validation {
    condition = contains([
      "AppGwSslPolicy20170401S",
      "AppGwSslPolicy20220101",
      "AppGwSslPolicy20220101S",
    ], var.ssl_policy_name)
    error_message = "Use a TLS 1.2+ policy: AppGwSslPolicy20220101, AppGwSslPolicy20220101S or AppGwSslPolicy20170401S. The older 20150501/20170401 policies allow TLS 1.0/1.1 and Azure rejects them."
  }
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
