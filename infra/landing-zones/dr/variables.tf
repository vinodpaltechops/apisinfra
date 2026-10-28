variable "org_name" {
  type    = string
  default = "vinorg"
}

variable "common_tags" {
  type    = map(string)
  default = {}
}

variable "jump_vnet_name" {
  description = "Name of the existing jump VNet in the dev landing zone. The mgmt VM lives here and manages BOTH clusters, so this spoke peers to it directly (peering is non-transitive, so jump↔hub does not reach here)."
  type        = string
  default     = "vnet-jump-dev-001"
}

variable "jump_address_space" {
  description = "Jump VNet CIDR — allowed inbound to this spoke via the NSG's mgmt rule. NSG is enforced on private-endpoint subnets, so without this the mgmt VM can route to the DR API server but gets dropped at the subnet."
  type        = string
  default     = "10.4.0.0/24"
}

# NOTE: there is deliberately no `location` variable. The DR region is defined
# once, in infra/platform/connectivity/dr.tf, and read from that layer's
# dr_location output. A second definition here is how the AKS private DNS zone
# and the cluster end up in different regions — a failure that surfaces ~45
# minutes into a cluster create, as an unresolvable API server.
