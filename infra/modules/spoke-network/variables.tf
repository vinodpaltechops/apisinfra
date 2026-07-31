variable "env" {
  description = "Environment short name (dev/qa/prod) — used in resource names and subnet keys."
  type        = string
}

variable "org_name" {
  type = string
}

variable "location" {
  type = string
}

variable "address_space" {
  description = "Spoke VNet /16 CIDR, e.g. 10.1.0.0/16. Subnets are derived from this."
  type        = string
}

variable "hub_address_space" {
  description = "Hub VNet CIDR — allowed inbound to the spoke via NSG."
  type        = string
  default     = "10.0.0.0/16"
}

variable "dns_servers" {
  description = "Custom DNS servers for the spoke VNet (hub Private DNS Resolver inbound IP)."
  type        = list(string)
  default     = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
