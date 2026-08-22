# MODULE: velero-backend
# The Azure half of a Velero installation: the object store that holds backups,
# and the identity Velero uses to reach it. The in-cluster half (the Helm
# release, the BackupStorageLocation, the Schedules) is GitOps — see
# k8s/gitops/platform/velero.
#
# ── Authentication: workload identity, no secrets ─────────────────────────────
# Velero authenticates as a user-assigned managed identity through the cluster's
# OIDC issuer. The AKS module already enables both halves of that
# (oidc_issuer_enabled + workload_identity_enabled), so all that is needed here
# is a federated credential per cluster, matching the velero ServiceAccount.
#
# Consequently `shared_access_key_enabled = false` below: the storage account
# has NO access keys at all, and no SAS token can be minted from one. Every
# caller must present an Entra token and hold an RBAC role. This is the single
# most valuable control on a backup store — a leaked key is otherwise a
# complete bypass of everything else, and backups are exactly what ransomware
# goes looking for.
#
# ── One store, both regions ───────────────────────────────────────────────────
# Both clusters federate into the SAME identity and the SAME container. That is
# deliberate: a backup taken in the primary region must be restorable by the DR
# cluster without copying anything. Velero namespaces its own objects by backup
# name, so two clusters sharing a bucket do not collide as long as their
# BackupStorageLocation prefixes differ — which is what `prefix` in the DR
# values file is for.

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
  }
}

# ── Object store ──────────────────────────────────────────────────────────────
resource "azurerm_storage_account" "velero" {
  name                = var.storage_account_name
  resource_group_name = var.resource_group_name
  location            = var.location

  account_tier             = "Standard"
  account_kind             = "StorageV2"
  account_replication_type = var.account_replication_type
  access_tier              = "Hot"

  # No keys, no SAS — Entra tokens only. See the header.
  shared_access_key_enabled = false

  # HTTPS-only is the provider default on StorageV2; left implicit rather than
  # set, because the explicit argument is deprecated in later azurerm 3.x.
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  public_network_access_enabled   = var.public_network_access_enabled

  blob_properties {
    # Versioning + soft delete are the ransomware controls that matter here: a
    # Velero client that is compromised (or simply buggy) can call delete, and
    # these keep the bytes recoverable for the retention window regardless.
    versioning_enabled = true

    delete_retention_policy {
      days = var.backup_soft_delete_days
    }

    container_delete_retention_policy {
      days = var.backup_soft_delete_days
    }
  }

  # network_rules is deliberately NOT set. The account has no keys, so its only
  # door is Entra + RBAC, and the AKS clusters reach it over their load-balancer
  # egress from two different regions with IPs that Azure may rotate. Pinning an
  # IP allowlist here buys little and breaks backups silently when the egress IP
  # changes — the failure surfaces as a missed backup, which nobody notices
  # until a restore. The private-endpoint path is the real hardening step; it
  # needs a PE + privatelink.blob zone link per region.

  tags = var.tags
}

# azurerm 3.x addresses the account by NAME here (storage_account_id is the
# 4.x form). The provider is pinned to ~> 3.110 repo-wide, so this is the
# correct argument — swapping it is part of a provider major upgrade, not a
# free modernisation.
resource "azurerm_storage_container" "velero" {
  name                  = var.container_name
  storage_account_name  = azurerm_storage_account.velero.name
  container_access_type = "private"
}

# ── Velero's identity ─────────────────────────────────────────────────────────
resource "azurerm_user_assigned_identity" "velero" {
  name                = var.identity_name
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

# Read AND write: Velero uploads backup tarballs and Kopia repository data, and
# prunes them when a backup's TTL expires. Blob Data Contributor is the minimum
# that covers both; Blob Data Owner would additionally allow changing ACLs,
# which Velero never does.
resource "azurerm_role_assignment" "velero_blob" {
  scope                = azurerm_storage_account.velero.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.velero.principal_id
}

# ── Federated credentials — one per cluster ───────────────────────────────────
# The subject MUST match the ServiceAccount Velero actually runs as. If the
# Helm release is installed into a different namespace, or the SA is renamed,
# the token exchange fails with AADSTS70021 (no matching federated identity
# record) and every backup fails at "failed to get credentials".
#
# MAP with static keys ("primary", "dr"), never keyed on the issuer URL: the URL
# is an apply-time attribute of a cluster that may not exist yet, and for_each
# keys must be known at plan time — the same trap documented in the aks module's
# additional_admin_principals.
resource "azurerm_federated_identity_credential" "velero" {
  for_each = var.federated_clusters

  name                = "fedcred-velero-${each.key}"
  resource_group_name = var.resource_group_name
  parent_id           = azurerm_user_assigned_identity.velero.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = each.value
  subject             = "system:serviceaccount:${var.velero_namespace}:${var.velero_service_account}"
}

# ── Snapshot rights on each cluster's node resource group ─────────────────────
# OFF by default, and generating nothing — see enable_snapshot_role.
#
# Only the CSI/volume-snapshot data mover needs these. The configured backup
# path (k8s/gitops/platform/velero) is Kopia filesystem backup, which reads the
# volume through the node agent and writes to blob; that requires nothing here.
#
# The reason snapshots are not used is regional, not performance: an Azure
# managed-disk snapshot cannot be restored outside the region it was taken in
# without an explicit cross-region copy. Snapshots are much faster per GB, which
# is exactly what makes them tempting — and they would quietly fail the only
# restore that matters here.
#
# Contributor is broader than ideal if you do turn this on. Velero needs to
# create snapshots from disks AND disks from snapshots, which spans two built-in
# roles ("Disk Snapshot Contributor" + "Disk Contributor"); the scope is the
# AKS-managed node resource group, which holds nothing but cluster
# infrastructure. Narrow it to those two if you prefer a second role assignment
# to the wider blast radius.
resource "azurerm_role_assignment" "velero_snapshot" {
  for_each = var.enable_snapshot_role ? var.snapshot_scopes : {}

  scope                = each.value
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.velero.principal_id
}
