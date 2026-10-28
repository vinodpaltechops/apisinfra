variable "env" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "subnet_id" {
  description = "Subnet for the Key Vault private endpoint (typically the spoke's snet-data)."
  type        = string
}

variable "vault_private_dns_zone_id" {
  description = "ID of the shared privatelink.vaultcore zone from the hub (connectivity) layer."
  type        = string
}

variable "vm_identity_principal_id" {
  description = "Object ID of the VM managed identity granted Secrets User. Ignored when grant_vm_identity_access is false."
  type        = string
  default     = null
}

variable "grant_vm_identity_access" {
  description = "Create the VM identity's role assignments. A separate flag rather than a null check on vm_identity_principal_id: that ID is unknown until apply when a VM supplies it, and count cannot depend on an unknown value. Set false when the landing zone has no VM."
  type        = bool
  default     = true
}

variable "allowed_ip_rules" {
  description = "Workstation IP(s)/CIDRs allowed through the KV data-plane firewall."
  type        = list(string)
  default     = []
}

variable "db_password_value" {
  type      = string
  sensitive = true
  default   = "SuperSecret123!"
}

variable "app_config_value" {
  type    = string
  default = "my-application-configuration-string"
}

variable "public_network_access_enabled" {
  description = <<-EOT
    false (default) removes the vault's public endpoint entirely. Most private,
    but it also makes the whole network_acls block inert — ip_rules, the
    AzureServices bypass and any VNet rules stop applying, because there is no
    endpoint left for a firewall to guard.

    Set true when an Azure service must read from this vault from OUTSIDE your
    VNet. Application Gateway is the case here: it fetches its TLS certificate
    from its control plane, which is not in your VNet and so cannot use the
    private endpoint, and fails with
    ApplicationGatewayKeyVaultSecretAccessDenied.

    true does NOT expose the vault — default_action stays "Deny", so the
    internet still gets nothing. It just re-activates the firewall so the
    AzureServices bypass and ip_rules take effect. The private endpoint
    continues to work exactly as before.
  EOT
  type        = bool
  default     = false
}

variable "allowed_subnet_ids" {
  description = <<-EOT
    Subnets allowed through the vault firewall (a VNet rule). Only meaningful
    when public_network_access_enabled = true.

    Each subnet must ALREADY EXIST and have the Microsoft.KeyVault service
    endpoint enabled when this module applies — so it can only reference
    subnets built in an earlier layer. The App Gateway subnet does not qualify:
    it is created by the appgw layer, which deploys AFTER this one. The
    AzureServices bypass already covers App Gateway, so no VNet rule is needed
    for it.
  EOT
  type        = list(string)
  default     = []
}

variable "grant_vm_certificate_officer" {
  description = <<-EOT
    Grant the VM's managed identity "Key Vault Certificates Officer" so it can
    run `az keyvault certificate import` from the mgmt VM.

    Needed for the App Gateway TLS workflow (docs/public-endpoint.md): the vault
    has no public endpoint, so the import must run inside the VNet, and on a
    headless VM `az login --identity` is the only usable sign-in — which means
    the identity itself needs write access. Secrets User alone returns 403.

    Default false because this is write access to private keys. Turn it on to
    install or renew a certificate; turning it back off afterwards does not
    affect the gateway, which only ever reads the cert via its own identity.
  EOT
  type        = bool
  default     = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
