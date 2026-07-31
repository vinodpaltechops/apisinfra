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
