variable "org_name" {
  description = "Short lowercase org name used in all resource names. E.g. 'contoso'."
  type        = string
  default     = "vinorg"
}

variable "location" {
  description = "Primary Azure region for all resources."
  type        = string
  default     = "southindia"
}
