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
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
  }
  backend "azurerm" {
    # resource_group_name + storage_account_name come from infra/backend.json:
    #   terraform init -backend-config=../../backend.json
    container_name = "velero"
    key            = "velero.tfstate"
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }

  # ── REQUIRED because the backup store has shared_access_key_enabled = false ──
  # Without this the provider performs its data-plane calls — the post-create
  # "waiting for the Blob Service to become available" poll, and every
  # azurerm_storage_container operation — using an ACCOUNT KEY. On a
  # keys-disabled account Azure rejects those with:
  #
  #   403 Key based authentication is not permitted on this storage account
  #   (KeyBasedAuthenticationNotPermitted)
  #
  # which reads like a permissions problem and is actually the provider
  # reaching for a credential that deliberately does not exist.
  #
  # This flag switches those calls to Entra tokens. It is provider-wide, but
  # this layer manages nothing else in Storage, so the blast radius is nil.
  storage_use_azuread = true
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

# State storage account + resource group. Same file `terraform init` reads via
# -backend-config, so the name lives in exactly one place.
locals {
  tfstate_backend = jsondecode(file("${path.module}/../../backend.json"))

  # Same naming scheme, same suffix: bumping backend.json past a taken name
  # moves the backup store with it.
  storage_account_name = coalesce(
    var.storage_account_name,
    replace(local.tfstate_backend.storage_account_name, "stotfstate", "stovelero"),
  )
}

data "terraform_remote_state" "dev" {
  backend = "azurerm"
  config = merge(local.tfstate_backend, {
    container_name = "landing-zones-dev"
    key            = "landing-zones-dev.tfstate"
  })
}

# count, not a plain data block: with enable_dr = false the DR state file does
# not exist yet, and an unconditional read fails at init/plan rather than
# degrading gracefully.
data "terraform_remote_state" "dr" {
  count = var.enable_dr ? 1 : 0

  backend = "azurerm"
  config = merge(local.tfstate_backend, {
    container_name = "landing-zones-dr"
    key            = "landing-zones-dr.tfstate"
  })
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

  storage_account_name = local.storage_account_name
  resource_group_name  = azurerm_resource_group.velero.name

  # PRIMARY region. Geo-replication places the secondary in southindia's Azure
  # pair, which is centralindia — NOT in dr_location, since indiasouthcentral
  # has no pairing of its own and pairing is a fixed property of the primary
  # region, not a choice.
  #
  # So the DR cluster (indiasouthcentral) reads backups one region away rather
  # than locally. RA-GRS secondary endpoints are globally reachable, so this
  # costs restore bandwidth and latency, not correctness — and the backups are
  # still outside southindia, which is the property that actually matters.
  location = var.location

  account_replication_type = var.account_replication_type
  backup_soft_delete_days  = var.backup_soft_delete_days

  federated_clusters = local.federated_clusters
  snapshot_scopes    = local.snapshot_scopes

  tags = local.tags
}
