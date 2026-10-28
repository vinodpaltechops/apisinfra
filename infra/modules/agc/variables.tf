variable "env" {
  type = string
}

variable "org_name" {
  type = string
}

variable "location" {
  description = "Must be a region that offers Application Gateway for Containers, and must be the AKS cluster's region. Check: az provider show -n Microsoft.ServiceNetworking --query \"resourceTypes[?resourceType=='trafficControllers'].locations[]\" -o tsv"
  type        = string
}

variable "vnet_name" {
  description = "Name of the spoke VNet the AKS cluster lives in. The gateway's data plane has to be in this VNet to reach the overlay pod IPs."
  type        = string
}

variable "vnet_resource_group_name" {
  description = "Resource group of that VNet."
  type        = string
}

variable "subnet_address_prefix" {
  description = "Delegated subnet for the gateway. At least a /24, inside the spoke range, and unused: the spoke module takes .1 to .4."
  type        = string
  default     = "10.1.5.0/24"
}

variable "allowed_source_prefixes" {
  description = <<-EOT
    Who may reach ports 80/443.

    Either a single service tag — ["Internet"] (default), which is the point of
    a public gateway — or a list of real CIDRs, e.g. ["163.223.165.0/24"], to
    keep it private while testing. Do not mix the two: Azure accepts a service
    tag only in the singular source_address_prefix field. The module picks the
    correct field for you.
  EOT
  type        = list(string)
  default     = ["Internet"]
}

variable "aks_oidc_issuer_url" {
  description = "The cluster's OIDC issuer URL (dev landing zone output aks_oidc_issuer_url). Trust anchor for the ALB Controller's federated credential."
  type        = string
}

variable "aks_node_resource_group_name" {
  description = "The cluster's node resource group (MC_...), from the dev landing zone."
  type        = string
}

variable "alb_namespace" {
  description = "Namespace the ALB Controller is installed into. The Helm chart's default."
  type        = string
  default     = "azure-alb-system"
}

variable "alb_service_account" {
  description = "Service account the ALB Controller runs as. The Helm chart's default; the federated credential trusts exactly this subject."
  type        = string
  default     = "alb-controller-sa"
}

variable "tags" {
  type    = map(string)
  default = {}
}
