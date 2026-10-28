variable "org_name" {
  type    = string
  default = "vinorg"
}

variable "location" {
  description = "Must equal the dev landing zone's location (the gateway has to be in the cluster's VNet) and be a region that offers Application Gateway for Containers."
  type        = string
  default     = "centralindia"
}

variable "subnet_address_prefix" {
  description = "Delegated subnet for the gateway (at least a /24) inside the dev spoke's 10.1.0.0/16, clear of .1 to .4."
  type        = string
  default     = "10.1.5.0/24"
}

variable "allowed_source_prefixes" {
  description = "Who may reach ports 80/443: [\"Internet\"] (a service tag, the default) or a list of CIDRs. Do not mix."
  type        = list(string)
  default     = ["Internet"]
}

variable "common_tags" {
  type    = map(string)
  default = {}
}
