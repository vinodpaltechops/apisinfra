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

variable "enable_https" {
  description = <<-EOT
    Master switch for TLS.

    false (default) — one listener on :80 serving the app. A complete, working
                      configuration; the gateway does not need a certificate to
                      be useful.
    true            — adds a :443 listener. Requires exactly one certificate
                      source below.

    Toggling this is non-destructive: it only adds or removes listeners and
    routing rules on the existing gateway. The public IP is untouched, so the
    DNS record never has to change.
  EOT
  type        = bool
  default     = false
}

variable "http_redirect_to_https" {
  description = <<-EOT
    Only meaningful when enable_https = true.

    true (default) — :80 returns a permanent redirect to :443. The right answer
                     for a public site: nothing is served in clear text.
    false          — :80 keeps serving the app directly, alongside :443, so
                     both http:// and https:// work. Useful while testing a
                     certificate, but it does mean the app remains reachable
                     unencrypted.
  EOT
  type        = bool
  default     = true
}

# ── Certificate source: supply exactly ONE when enable_https = true ───────────

variable "ssl_certificate_pfx_path" {
  description = <<-EOT
    Path to a PFX/PKCS12 file, uploaded to the gateway by Terraform. Needs no
    Key Vault and no managed identity, so it works from a CI runner that has no
    network path to a private vault — the simplest way to get HTTPS.

    TRADE-OFF: the PFX (private key included) is stored in Terraform state.
    State lives in the backend storage account, encrypted at rest and
    access-controlled, but anyone who can read state can read the key. Use the
    Key Vault source instead if that matters.
  EOT
  type        = string
  default     = null
}

variable "ssl_certificate_pfx_password" {
  description = "Password for ssl_certificate_pfx_path. Pass \"\" for a PFX exported without one. Supply via TF_VAR_ssl_certificate_pfx_password, never in a committed tfvars file."
  type        = string
  default     = null
  sensitive   = true
}

variable "ssl_certificate_key_vault_secret_id" {
  description = <<-EOT
    Key Vault SECRET id of the certificate (not the certificate id), in the
    UNVERSIONED form so the gateway picks up rotations automatically:
      https://<vault>.vault.azure.net/secrets/<cert-name>

    The private key never enters Terraform state — the gateway fetches it at
    runtime using a managed identity this module creates and grants access for
    (see key_vault_id). Requires key_vault_id.

    The certificate itself must already exist in the vault. That import is a
    data-plane operation, so against a private-endpoint-only vault it has to be
    run from inside the VNet — see docs/public-endpoint.md.
  EOT
  type        = string
  default     = null
}

variable "key_vault_id" {
  description = "Resource ID of the vault holding the certificate. Required with ssl_certificate_key_vault_secret_id: the module creates a user-assigned identity and grants it Key Vault Secrets User here, so no manual az role assignment is needed."
  type        = string
  default     = null

  validation {
    condition     = var.key_vault_id == null || can(regex("/providers/Microsoft.KeyVault/vaults/", var.key_vault_id))
    error_message = "key_vault_id must be a full Key Vault resource ID (/subscriptions/.../providers/Microsoft.KeyVault/vaults/<name>)."
  }
}

variable "tags" {

  type    = map(string)
  default = {}
}
