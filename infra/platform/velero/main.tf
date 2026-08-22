# LAYER: VELERO — the backup store both clusters share.
#
# Deployed AFTER both landing zones, because it federates each cluster's OIDC
# issuer into Velero's managed identity. It creates no Kubernetes objects at
# all: the Helm release, the BackupStorageLocation and the Schedules are
# delivered by ArgoCD from k8s/gitops/platform/velero.
#
# Its own state file, per the one-state-per-layer rule. That matters more here
# than elsewhere — the backup store must be destroyable and rebuildable
# independently of the clusters it protects, and more importantly must NOT be
# destroyed when a cluster is. A `terraform destroy` of the dev landing zone
# leaves this layer, and therefore every backup, untouched.
#
# ── Removing DR from this layer ───────────────────────────────────────────────
# Set enable_dr = false and apply. That drops the DR cluster's federated
# credential and snapshot role assignment; the storage account, the identity and
# every existing backup are unaffected. The whole layer can also be commented
# out of the deploy pipeline — but do NOT destroy it casually, because that
# deletes the backups.

terraform {
  required_version = ">= 1.7.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
  }
  backend "azurerm" {
    resource_group_name  = "rg-tfstate-vinorg-001"
    storage_account_name = "stotfstatevinorg001"
    container_name       = "velero"
    key                  = "velero.tfstate"
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

locals {
  tags = merge(var.common_tags, {
    Layer      = "Velero"
    CostCenter = "CloudPlatform"
    Role       = "DisasterRecovery"
  })

  # Federate the primary cluster always; add DR only when it exists. Static map
  # keys ("primary"/"dr") — the issuer URLs are apply-time attributes of the
  # clusters, and for_each keys must be known at plan time.
  federated_clusters = merge(
    { primary = data.terraform_remote_state.dev.outputs.aks_oidc_issuer_url },
    var.enable_dr ? { dr = data.terraform_remote_state.dr[0].outputs.aks_oidc_issuer_url } : {},
  )

  # Snapshot rights are granted on each cluster's AKS-managed NODE resource
  # group (MC_*), which is where the managed disks behind PVCs actually live —
  # not the spoke resource group.
  snapshot_scopes = merge(
    { primary = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${data.terraform_remote_state.dev.outputs.aks_node_resource_group}" },
    var.enable_dr ? { dr = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${data.terraform_remote_state.dr[0].outputs.aks_node_resource_group}" } : {},
  )
}

data "azurerm_client_config" "current" {}

data "terraform_remote_state" "dev" {
  backend = "azurerm"
  config = {
    resource_group_name  = "rg-tfstate-vinorg-001"
    storage_account_name = "stotfstatevinorg001"
    container_name       = "landing-zones-dev"
    key                  = "landing-zones-dev.tfstate"
  }
}

# count, not a plain data block: with enable_dr = false the DR state file does
# not exist yet, and an unconditional read fails at init/plan rather than
# degrading gracefully.
data "terraform_remote_state" "dr" {
  count = var.enable_dr ? 1 : 0

  backend = "azurerm"
  config = {
    resource_group_name  = "rg-tfstate-vinorg-001"
    storage_account_name = "stotfstatevinorg001"
    container_name       = "landing-zones-dr"
    key                  = "landing-zones-dr.tfstate"
  }
}

# ── Resource group ────────────────────────────────────────────────────────────
# Separate from both spokes on purpose: deleting a spoke's resource group is a
# normal, recoverable operation, and it must not take the backups with it.
resource "azurerm_resource_group" "velero" {
  name     = "rg-velero-${var.org_name}-001"
  location = var.location
  tags     = local.tags
}

module "velero_backend" {
  source = "../../modules/velero-backend"

  storage_account_name = var.storage_account_name
  resource_group_name  = azurerm_resource_group.velero.name

  # PRIMARY region. Geo-replication places the secondary copy in its Azure pair
  # automatically — with dr_location = centralindia (southindia's pair), that
  # secondary lands in the DR region, which is the entire point.
  location = var.location

  account_replication_type = var.account_replication_type
  backup_soft_delete_days  = var.backup_soft_delete_days

  federated_clusters = local.federated_clusters
  snapshot_scopes    = local.snapshot_scopes

  tags = local.tags
}
