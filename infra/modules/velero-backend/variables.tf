variable "storage_account_name" {
  description = "Globally unique storage account name for the backup store. 3-24 chars, lowercase alphanumeric only."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "storage_account_name must be 3-24 lowercase alphanumeric characters (no hyphens or underscores)."
  }
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  description = "Region for the backup store. Use the PRIMARY region — geo-replication puts the secondary copy in its Azure pair automatically."
  type        = string
}

variable "account_replication_type" {
  description = <<-EOT
    RAGRS (default) replicates to the Azure paired region AND exposes a
    read-only secondary endpoint. That read-only endpoint is the whole point:
    during a primary-region outage the DR cluster can list and download backups
    immediately, with no failover step and no support ticket.

    Plain GRS replicates identically but keeps the secondary INVISIBLE until you
    initiate an account failover, which is a deliberate, account-wide, and
    occasionally slow operation — exactly the wrong thing to discover mid
    incident. The price difference is a few cents per GB per month.

    LRS is single-region and therefore not a DR configuration at all: the
    backups die with the region that holds the cluster they protect.
  EOT
  type        = string
  default     = "RAGRS"

  validation {
    condition     = contains(["LRS", "ZRS", "GRS", "RAGRS", "GZRS", "RAGZRS"], var.account_replication_type)
    error_message = "account_replication_type must be one of LRS, ZRS, GRS, RAGRS, GZRS, RAGZRS."
  }
}

variable "public_network_access_enabled" {
  description = "Keep true unless you have added a private endpoint + privatelink.blob zone link in BOTH regions. The account has no access keys, so its exposure is an Entra-authenticated endpoint, not an open bucket."
  type        = bool
  default     = true
}

variable "backup_soft_delete_days" {
  description = "Retention window for deleted blobs and containers. Must exceed the longest Velero backup TTL, or an expired-then-deleted backup becomes unrecoverable before you notice it was needed."
  type        = number
  default     = 30

  validation {
    condition     = var.backup_soft_delete_days >= 1 && var.backup_soft_delete_days <= 365
    error_message = "backup_soft_delete_days must be between 1 and 365."
  }
}

variable "container_name" {
  description = "Blob container holding backups. Both clusters share it; they are separated by BackupStorageLocation prefix, not by container."
  type        = string
  default     = "velero"
}

variable "identity_name" {
  type    = string
  default = "id-velero"
}

variable "velero_namespace" {
  description = "Namespace Velero runs in. Must match the Helm release namespace — it forms half the federated credential subject."
  type        = string
  default     = "velero"
}

variable "velero_service_account" {
  description = "Velero's ServiceAccount name. Must match serviceAccount.server.name in the Helm values — it forms the other half of the federated credential subject."
  type        = string
  default     = "velero"
}

variable "federated_clusters" {
  description = <<-EOT
    Clusters whose Velero may use this identity: { <label> = <oidc_issuer_url> }.
    Typically { primary = ..., dr = ... }.

    MAP with STATIC keys, never keyed on the issuer URL. The URL is an
    apply-time attribute of the AKS cluster, and for_each keys must be known at
    PLAN time — keying on it makes plan fail with "Invalid for_each argument"
    the moment the cluster does not yet exist, and makes destroy fail the same
    way. This is the identical trap documented in the aks module's
    additional_admin_principals; only the values may be apply-time unknowns.

    Dropping an entry removes that cluster's ability to authenticate WITHOUT
    touching the backups, which is the intended way to decommission a cluster.
  EOT
  type        = map(string)
}

variable "enable_snapshot_role" {
  description = <<-EOT
    Grant Velero rights to manage disk snapshots in the scopes below.

    false (default) because the in-cluster configuration deliberately does NOT
    use snapshots: an Azure managed-disk snapshot is region-locked and cannot be
    restored in the DR region without a copy step, so
    k8s/gitops/platform/velero uses Kopia filesystem backup into blob instead.
    That path needs no snapshot rights at all.

    Leaving this false keeps a broad Contributor assignment off the node
    resource groups for a capability nothing currently uses. Set it true only if
    you add a volumeSnapshotLocation — and then read the note in main.tf about
    narrowing Contributor to the two disk roles.
  EOT
  type        = bool
  default     = false
}

variable "snapshot_scopes" {
  description = <<-EOT
    Scopes granted snapshot rights: { <label> = <resource id> }. Pass each
    cluster's NODE resource group (the AKS-managed MC_* group that holds the
    disks), not the spoke resource group.

    Same static-key rule as federated_clusters — the node RG id is an apply-time
    attribute of the cluster.
  EOT
  type        = map(string)
  default     = {}
}

variable "tags" {
  type    = map(string)
  default = {}
}
