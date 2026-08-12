variable "registry_name" {
  description = "Globally unique registry name. Alphanumeric only, 5-50 chars — no hyphens (ACR rejects them)."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9]{5,50}$", var.registry_name))
    error_message = "registry_name must be 5-50 alphanumeric characters, no hyphens or underscores."
  }
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "sku" {
  description = "Basic keeps the lab cheap (~$5/mo). Premium is required for private endpoints, geo-replication and retention policies."
  type        = string
  default     = "Basic"

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.sku)
    error_message = "sku must be one of Basic, Standard, Premium."
  }
}

variable "public_network_access_enabled" {
  description = "Only honoured on Premium — Basic and Standard are always publicly reachable."
  type        = bool
  default     = true
}

variable "kubelet_identity_object_id" {
  description = "AKS kubelet managed identity object ID — granted AcrPull so nodes pull without an imagePullSecret."
  type        = string
}

variable "push_principal_ids" {
  description = "Extra principal object IDs granted AcrPush (scoped CI identities, build VMs). The root-MG Owner SP already has push rights and does not need listing."
  type        = list(string)
  default     = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
