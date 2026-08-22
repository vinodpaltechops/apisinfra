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

variable "geo_replication_locations" {
  description = <<-EOT
    Extra regions to replicate the registry into, e.g. ["centralindia"]. Must
    NOT include the registry's own location — Azure rejects that as a duplicate.

    Empty (default) generates no georeplications block at all, leaving Basic
    registries exactly as they were.

    PREMIUM ONLY. Setting this on Basic or Standard fails the apply with
    "Geo-replication is not supported for the <sku> SKU", which is the intended
    behaviour: silently ignoring it would leave you believing the DR region has
    a local registry when it does not.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.geo_replication_locations) == 0 || var.sku == "Premium"
    error_message = "geo_replication_locations requires sku = \"Premium\". Set both together, or leave the list empty."
  }
}

variable "kubelet_identity_object_id" {
  description = "AKS kubelet managed identity object ID — granted AcrPull so nodes pull without an imagePullSecret."
  type        = string
}

variable "push_principals" {
  description = <<-EOT
    Principals granted AcrPush (scoped CI identities, build VMs). The root-MG
    Owner SP already has push rights and does not need listing.

    MAP with static keys (e.g. { build_vm = <principal id> }), not a list: a
    principal ID sourced from a managed identity is unknown until apply, and
    for_each keys must be known at plan time — keying on the ID itself breaks
    plan and destroy with "Invalid for_each argument".
  EOT
  type        = map(string)
  default     = {}
}

variable "tags" {
  type    = map(string)
  default = {}
}
