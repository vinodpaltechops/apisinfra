variable "org_name" {
  type    = string
  default = "vinorg"
}

variable "location" {
  type    = string
  default = "southindia"
}

variable "admin_password" {
  description = "Test VM local admin password (Windows complexity rules). Set in terraform.tfvars."
  type        = string
  sensitive   = true
}

variable "allowed_ip_rules" {
  description = "Workstation IP(s)/CIDRs allowed through the Key Vault firewall. Set in terraform.tfvars."
  type        = list(string)
  default     = []
}

variable "common_tags" {
  type    = map(string)
  default = {}
}

variable "mgmt_ssh_source_prefix" {
  description = "CIDR allowed to SSH into the public mgmt VM (your home/ISP public IP, e.g. 163.223.165.0/24). It's your only internet-facing door — keep it tight."
  type        = string
  default     = "163.223.165.0/24"
}

variable "keyvault_public_network_access_enabled" {
  description = "true re-activates the Key Vault firewall so App Gateway (a trusted Azure service) can fetch the TLS certificate. default_action stays Deny, so the vault is still not internet-reachable. Required whenever the appgw layer uses the Key Vault certificate source."
  type        = bool
  default     = true
}

variable "grant_vm_certificate_officer" {
  description = "Grant the mgmt VM's identity Key Vault Certificates Officer so it can import the App Gateway TLS certificate. Set true while installing or renewing a cert; see docs/public-endpoint.md."
  type        = bool
  default     = false
}

variable "acr_name" {
  description = "Globally unique ACR name (alphanumeric only). Change it if `az acr check-name -n <name>` says it is taken."
  type        = string
  default     = "acrdevvinorg001"
}

variable "acr_sku" {
  description = "Basic is enough for this lab. Premium only if you move the registry behind a private endpoint."
  type        = string
  default     = "Basic"
}

variable "ssh_public_key" {
  description = "SSH public key CONTENT for the jump + mgmt VMs. Set in CI via TF_VAR_ssh_public_key (a GitHub variable). Leave null locally to read ~/.ssh/id_rsa.pub instead."
  type        = string
  default     = null
}
