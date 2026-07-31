variable "env" {
  type = string
}

variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "system_subnet_id" {
  description = "Subnet for the system node pool (spoke's snet-aks-system)."
  type        = string
}

variable "user_subnet_id" {
  description = "Subnet for the user node pool (spoke's snet-aks-user)."
  type        = string
}

# Re-enable for a PRIVATE cluster (used by the DNS-zone links in main.tf):
# variable "hub_vnet_id" {
#   type = string
# }
#
# variable "spoke_vnet_id" {
#   type = string
# }

variable "law_id" {
  description = "Hub Log Analytics workspace ID for the OMS agent."
  type        = string
}

variable "jump_vm_principal_id" {
  description = "Jump VM managed identity — granted AKS cluster admin/user."
  type        = string
}

variable "kubernetes_version" {
  description = "AKS version. null = let AKS pick the region's default. Check: az aks get-versions --location <region> -o table"
  type        = string
  default     = null
}

variable "system_node_vm_size" {
  type = string
  # Matches the currently-deployed system node (2 vCPU / 8 GiB). Changing this
  # forces a node-pool ROTATION, which needs a temporary surge of +2 vCPU —
  # you don't have that under the 4-vCPU regional quota, so keep it as-is.
  default = "Standard_D2as_v5"
}

variable "user_node_vm_size" {
  type    = string
  default = "Standard_D2as_v5" # only used when the user node pool is re-enabled
}

variable "pod_cidr" {
  description = "Overlay pod CIDR — not routable in the VNet."
  type        = string
  default     = "192.168.0.0/16"
}

variable "service_cidr" {
  type    = string
  default = "172.16.0.0/16"
}

variable "dns_service_ip" {
  description = "Must be inside service_cidr."
  type        = string
  default     = "172.16.0.10"
}

variable "admin_group_object_ids" {
  description = "AAD group object IDs granted cluster-admin (empty for lab)."
  type        = list(string)
  default     = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
