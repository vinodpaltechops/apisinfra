variable "org_name" {
  type    = string
  default = "vinorg"
}

variable "location" {
  type    = string
  default = "southindia"
}

# Hub values (hub_vnet_id/name, resource group, DNS resolver IP) are read
# dynamically from the connectivity layer's remote state — see the
# terraform_remote_state data source and locals block in main.tf. The
# provider uses whichever subscription is active in the Azure CLI session
# (az account show).

variable "common_tags" {
  type    = map(string)
  default = {}
}
