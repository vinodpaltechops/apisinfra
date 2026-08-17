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
  description = "Object ID of the VM managed identity granted Secrets User."
  type        = string
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
