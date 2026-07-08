variable "spoke_vnet_name"          { type = string }
variable "spoke_vnet_id"            { type = string }
variable "spoke_resource_group_name" { type = string }
variable "hub_vnet_name"            { type = string }
variable "hub_vnet_id"              { type = string }
variable "hub_resource_group_name"  { type = string }
variable "hub_has_gateway" {
	type    = bool
	default = false
}
