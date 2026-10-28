variable "org_name" {
  type    = string
  default = "vinorg"
}

variable "location" {
  description = "Region for the metadata resource group ONLY. Azure DNS is global."
  type        = string
  default     = "southindia"
}

variable "zone_name" {
  description = "The registered domain this zone is authoritative for."
  type        = string
}

variable "app_fqdn" {
  description = "Hostname that becomes a CNAME to Traffic Manager. Must be inside zone_name, and must match app_fqdn in the appgw, appgw-dr and trafficmanager layers."
  type        = string

  validation {
    condition     = endswith(var.app_fqdn, ".${var.zone_name}")
    error_message = "app_fqdn must be a subdomain of zone_name."
  }
}

variable "app_ttl" {
  description = "TTL on the app CNAME. Keep it low: it caps how fast a rollback takes effect."
  type        = number
  default     = 600
}

variable "a_records" {
  description = "Extra A records, keyed by relative name (\"@\" for the apex)."
  type = map(object({
    ttl     = number
    records = list(string)
  }))
  default = {}
}

variable "cname_records" {
  description = "Extra CNAME records, keyed by relative name. Not valid at the apex."
  type = map(object({
    ttl    = number
    record = string
  }))
  default = {}
}

variable "txt_records" {
  description = "TXT records, keyed by relative name. Each name may hold several values."
  type = map(object({
    ttl    = number
    values = list(string)
  }))
  default = {}
}

variable "mx_records" {
  description = "MX records, keyed by relative name (\"@\" for the apex)."
  type = map(object({
    ttl = number
    records = list(object({
      preference = number
      exchange   = string
    }))
  }))
  default = {}
}

variable "common_tags" {
  type    = map(string)
  default = {}
}
