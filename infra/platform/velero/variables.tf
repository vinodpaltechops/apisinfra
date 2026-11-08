variable "org_name" {
  type    = string
  default = "vinorg"
}

variable "location" {
  description = "PRIMARY region — must match the dev landing zone's region. Geo-replication puts the secondary copy in its Azure pair, so this choice also determines where a DR restore reads from."
  type        = string
  default     = "southindia"
}

variable "storage_account_name" {
  description = "Override for the backup store's name. Leave null: it is derived from infra/backend.json (stotfstate... -> stovelero...), so one bump there renames both accounts. Must still be globally unique — check with `az storage account check-name -n <name>`."
  type        = string
  default     = null
}

variable "account_replication_type" {
  description = "RAGRS gives a read-only secondary in the paired region, readable during a primary outage with no failover step. See the module variable for the full comparison."
  type        = string
  default     = "RAGRS"
}

variable "backup_soft_delete_days" {
  description = "Blob/container soft-delete window. Must exceed the longest Velero backup TTL in k8s/gitops/platform/velero (currently 720h = 30d for the daily schedule)."
  type        = number
  default     = 30
}

variable "enable_dr" {
  description = <<-EOT
    Federate the DR cluster's OIDC issuer into Velero's identity, and grant it
    snapshot rights.

    false = primary-cluster backups only, and this layer stops reading the
    landing-zones-dr state entirely — which is what makes it safe to apply
    BEFORE the DR region exists. Flip it to true after the DR landing zone has
    been applied once.

    Turning it back off removes the DR cluster's ability to authenticate but
    touches neither the storage account nor any existing backup.
  EOT
  type        = bool
  default     = true
}

variable "common_tags" {
  type    = map(string)
  default = {}
}
