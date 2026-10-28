variable "org_name" {
  type    = string
  default = "vinorg"
}

# centralindia, not southindia: Application Gateway for Containers is not
# available in southindia, and it must sit in the same VNet (so region) as AKS.
variable "location" {
  type    = string
  default = "centralindia"
}

variable "aks_authorized_ip_ranges" {
  description = "CIDRs allowed to reach the public AKS API server — your laptop's egress IP as /32 (curl -s https://api.ipify.org). Empty leaves the endpoint open to the internet (Entra ID + Azure RBAC still apply). Not needed for the pipelines, which use `az aks command invoke`."
  type        = list(string)
  default     = []
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
  description = "Source allowed to SSH into the public mgmt VM: a CIDR (your ISP range) or the NSG service tag \"Internet\". It's the only internet-facing door; key-only auth is what protects it when open."
  type        = string
  default     = "Internet"
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
  description = "Basic is enough for this lab. Premium only if you move the registry behind a private endpoint, or geo-replicate it for DR (see acr_geo_replication_locations)."
  type        = string
  default     = "Basic"
}

variable "acr_geo_replication_locations" {
  description = <<-EOT
    Regions to geo-replicate the registry into for DR, e.g. ["indiasouthcentral"].
    Empty (default) = today's single-region Basic registry, unchanged.

    Requires acr_sku = "Premium" — set both together in dev.auto.tfvars or the
    apply fails the module's validation. Premium is roughly 10x Basic, which is
    the real reason this is off by default rather than a technical one.
  EOT
  type        = list(string)
  default     = []
}

variable "ssh_public_key" {
  description = "SSH public key CONTENT for the jump + mgmt VMs. Set in CI via TF_VAR_ssh_public_key (a GitHub variable). Leave null locally to read ~/.ssh/id_rsa.pub instead."
  type        = string
  default     = null
}
