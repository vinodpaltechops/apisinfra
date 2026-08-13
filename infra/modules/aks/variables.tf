variable "env" {
  type = string
}

variable "aks_private_dns_zone_id" {
  description = "Pre-created hub-linked privatelink.<region>.azmk8s.io zone ID (from connectivity) for the private cluster's BYO DNS."
  type        = string
}

variable "spoke_vnet_id" {
  description = "Dev spoke VNet ID. The AKS control-plane identity needs Network Contributor here so it can (a) join nodes into the subnets and (b) link the BYO private DNS zone to this VNet during private-cluster reconcile."
  type        = string
}

variable "grant_operator_cluster_admin" {
  description = "Grant the identity running Terraform (you) AKS RBAC Cluster Admin, so kubectl works from your workstation. Set false for prod-like use (access via the jump VM instead)."
  type        = bool
  default     = false
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

variable "additional_admin_principals" {
  description = <<-EOT
    Principals granted BOTH AKS roles needed to run kubectl:
    "Cluster User Role" (the ARM permission to fetch a kubeconfig) and "RBAC
    Cluster Admin" (the data-plane permission Azure RBAC then checks). One
    without the other fails — the first at `az aks get-credentials`, the second
    at the first kubectl call.

    Intended for the mgmt/bastion VM's managed identity. On a headless VM,
    `az login --identity` is the only workable sign-in: Entra security defaults
    block the device-code flow (AADSTS530035), and there is no browser for the
    interactive flow.

    MAP, not a list, and the keys must be static strings such as "mgmt_vm" —
    the principal IDs themselves come from managed identities and are unknown
    until apply. for_each keys have to be known at PLAN time, so keying on the
    IDs makes both plan and destroy fail with "Invalid for_each argument" as
    soon as the VM providing the ID does not yet exist (or is being destroyed).
    Static keys sidestep that: only the values are apply-time unknowns.
  EOT
  type        = map(string)
  default     = {}
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
