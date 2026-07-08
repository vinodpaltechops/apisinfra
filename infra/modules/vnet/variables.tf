variable "vnet_name"           { type = string }
variable "resource_group_name" { type = string }
variable "location"            { type = string }
variable "address_space"       { type = string }
variable "dns_servers" {
  type    = list(string)
  default = []
}
variable "tags" {
  type    = map(string)
  default = {}
}

variable "subnets" {
  description = "Map of subnet name → subnet config object."
  type = map(object({
    address_prefix     = string
    service_endpoints  = optional(list(string), [])
    delegation         = optional(object({
      name                     = string
      service_delegation_name  = string
      actions                  = list(string)
    }))
  }))
}
