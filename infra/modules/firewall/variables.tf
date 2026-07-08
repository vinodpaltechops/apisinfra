variable "firewall_name" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "firewall_subnet_id" {
  type = string
}

variable "dns_resolver_ips" {
  type    = list(string)
  default = []
}

variable "availability_zones" {
  type    = list(string)
  default = ["1", "2", "3"]
}

variable "tags" {
  type    = map(string)
  default = {}
}
