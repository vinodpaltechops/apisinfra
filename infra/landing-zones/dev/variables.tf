variable "org_name" {
  type    = string
  default = "vinorg"
}

variable "location" {
  type    = string
  default = "southindia"
}

# Hub values (hub_vnet_id/name, resource group, DNS resolver IP) are now read
# dynamically from the connectivity layer's remote state — see the
# terraform_remote_state data source and locals block in main.tf.
# dev_subscription_id, connectivity_subscription_id, hub_firewall_private_ip,
# and dev_team_group_object_id were only used by the provider block or
# commented-out (multi-subscription / firewall / RBAC) blocks, so their
# variable declarations were removed. The provider now uses whichever
# subscription is active in the Azure CLI session (az account show).

variable "common_tags" {
  type    = map(string)
  default = {}
}
