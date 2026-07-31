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

variable "tags" {
  type    = map(string)
  default = {}
}
