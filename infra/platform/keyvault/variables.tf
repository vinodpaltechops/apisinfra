variable "org_name" {
  type    = string
  default = "vinorg"
}

variable "location" {
  description = "Region of the vault's resource group. Key Vault is regional but reached by name, so this does not have to match the spoke."
  type        = string
  default     = "centralindia"
}

variable "allowed_ip_rules" {
  description = "Workstation IP(s)/CIDRs allowed through the vault firewall, e.g. your ISP range. This is how you import the TLS certificate from a laptop now that there is no mgmt VM."
  type        = list(string)
  default     = []
}

variable "public_network_access_enabled" {
  description = "true re-activates the vault firewall so App Gateway (a trusted Azure service) and allowed_ip_rules can reach it. default_action stays Deny, so the vault is still not internet-reachable. Required whenever a gateway reads its certificate from here."
  type        = bool
  default     = true
}

variable "common_tags" {
  type    = map(string)
  default = {}
}
