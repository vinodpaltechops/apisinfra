variable "env" {
  description = "Environment short name (dev/qa/prod) — used in resource names and subnet keys."
  type        = string
}

variable "org_name" {
  type = string
}

variable "location" {
  type = string
}

variable "address_space" {
  description = "Spoke VNet /16 CIDR, e.g. 10.1.0.0/16. Subnets are derived from this."
  type        = string
}

variable "hub_address_space" {
  description = "Hub VNet CIDR — allowed inbound to the spoke via NSG."
  type        = string
  default     = "10.0.0.0/16"
}

variable "mgmt_address_spaces" {
  description = "Extra CIDRs allowed inbound to the spoke (e.g. the jump VNet, which lives in its own region/address space and so isn't covered by hub_address_space). Needed for the jump VM to reach spoke private endpoints — NSG is enforced on the PE subnets."
  type        = list(string)
  default     = []
}

variable "dns_servers" {
  description = "Custom DNS servers for the spoke VNet (hub Private DNS Resolver inbound IP)."
  type        = list(string)
  default     = []
}

variable "aks_pod_cidr" {
  description = <<-EOT
    Pod CIDR of an Azure CNI Overlay AKS cluster in this spoke (e.g. 192.168.0.0/16),
    or null when the spoke has no AKS cluster.

    REQUIRED whenever AKS is present. Overlay pod traffic between nodes keeps the
    POD source/destination IPs — Azure does not SNAT it to the node IPs — so those
    packets match none of the 10.x allow rules below and get dropped by
    deny-all-inbound. Symptom: pods on one node cannot reach pods (including
    CoreDNS) on another, so DNS times out cluster-wide while every node still
    reports Ready.
  EOT
  type        = string
  default     = null
}

variable "tags" {
  type    = map(string)
  default = {}
}
