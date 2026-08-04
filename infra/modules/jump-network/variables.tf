variable "env" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  description = "Region for the jump VNet/VM (a different region than the spokes, for separate vCPU quota)."
  type        = string
}

variable "address_space" {
  description = "Jump VNet CIDR — must not overlap the hub/spokes (e.g. 10.4.0.0/24)."
  type        = string
}

variable "dns_servers" {
  description = "Custom DNS servers (hub Private DNS Resolver inbound IP) so the jump VM resolves private zones via the hub."
  type        = list(string)
  default     = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
