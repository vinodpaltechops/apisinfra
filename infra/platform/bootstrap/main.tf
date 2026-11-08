# LAYER 1 — BOOTSTRAP
# Purpose: creates the Azure Storage Account that will hold remote Terraform state
# for all subsequent layers. This is the ONLY layer whose state lives locally.
# Run this ONCE before anything else.

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
    # Reads each namespace's registration state — see the import block below.
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
  }
  # backend "azurerm" {
  #   container_name = "bootstrap"
  #   key            = "bootstrap.tfstate"
  # }
  # Bootstrap state is LOCAL — this is intentional.
  # All other layers point their backend here.
}

# The state account's name and resource group — the ONE place they are defined.
# Every other layer reads the same file: its backend via
# `terraform init -backend-config=../../backend.json`, its terraform_remote_state
# blocks via jsondecode. Storage account names are globally unique across all of
# Azure, so if the name is ever taken, change it there and nowhere else.
locals {
  tfstate_backend = jsondecode(file("${path.module}/../../backend.json"))
}

provider "azurerm" {
  features {}
  skip_provider_registration = true
  # Subscription comes from the active Azure CLI session (az account show)
  # or ARM_SUBSCRIPTION_ID env var — never put subscription IDs in code.
}

resource "azurerm_resource_group" "tfstate" {
  name     = local.tfstate_backend.resource_group_name
  location = var.location

  tags = {
    Purpose   = "Terraform remote state"
    ManagedBy = "Terraform bootstrap"
  }
  lifecycle {
    prevent_destroy = true
  }
}

# ── Resource provider registration — for the WHOLE stack, not just this layer ──
# A subscription must opt in to each Azure service namespace before it can
# create anything from it; otherwise ARM rejects the create with
# MissingSubscriptionRegistration. Every layer's provider runs with
# skip_provider_registration (here, and ARM_SKIP_PROVIDER_REGISTRATION in
# tf-layer.yml), so this is the one place the stack registers anything.
# Bootstrap owns it because it already runs once per subscription, before any
# other layer, and registration is subscription-wide.
#
# Derived from every azurerm_* resource type under infra/. Adding a layer that
# uses a new service means adding its namespace here and re-applying bootstrap.
locals {
  resource_providers = toset([
    "Microsoft.Cdn",                  # Front Door (platform/frontdoor)
    "Microsoft.Compute",              # VMs, VM extensions, AKS node VMSS
    "Microsoft.ContainerRegistry",    # ACR
    "Microsoft.ContainerService",     # AKS
    "microsoft.insights",             # diagnostic settings, AKS monitoring (Azure's own casing; the resource is case-sensitive)
    "Microsoft.KeyVault",             # Key Vault, AKS secrets-store CSI add-on
    "Microsoft.ManagedIdentity",      # user-assigned identities, workload identity federation
    "Microsoft.Management",           # management groups
    "Microsoft.Network",              # VNets, peering, NSGs, firewall, App Gateway, DNS, NAT, private endpoints
    "Microsoft.OperationalInsights",  # Log Analytics workspace
    "Microsoft.OperationsManagement", # AKS Container Insights (oms_agent)
    "Microsoft.PolicyInsights",       # policy compliance + DINE remediation
    "Microsoft.Storage",              # this layer's state account, Velero backup store
  ])
}

data "azurerm_client_config" "current" {}

# The registration resource REFUSES to create a namespace that is already
# registered ("already exists - needs to be imported"), and the portal registers
# namespaces as a side effect of browsing a service. So read each one's current
# state, and import the registered ones instead of creating them. That keeps the
# first apply hands-off on any subscription, fresh or not. Once they are in
# state the import is a no-op.
#
# Uses the az CLI, which bootstrap already requires (it authenticates the
# provider). --subscription pins it to the provider's subscription, in case
# ARM_SUBSCRIPTION_ID differs from the CLI's default.
data "external" "rp_state" {
  for_each = local.resource_providers
  program = [
    "az", "provider", "show",
    "--namespace", each.key,
    "--subscription", data.azurerm_client_config.current.subscription_id,
    "--query", "{state: registrationState}",
    "--output", "json",
  ]
}

import {
  for_each = { for ns, rp in data.external.rp_state : ns => rp if rp.result.state == "Registered" }
  to       = azurerm_resource_provider_registration.this[each.key]
  id       = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/${each.key}"
}

resource "azurerm_resource_provider_registration" "this" {
  for_each = local.resource_providers
  name     = each.key

  lifecycle {
    # Destroying this UNREGISTERS the namespace for the whole subscription.
    prevent_destroy = true
  }
}

resource "azurerm_storage_account" "tfstate" {
  # No attribute reference ties these together, so the ordering must be explicit.
  depends_on = [azurerm_resource_provider_registration.this]

  # From infra/backend.json — see the locals block at the top.
  name                            = local.tfstate_backend.storage_account_name
  resource_group_name             = azurerm_resource_group.tfstate.name
  location                        = azurerm_resource_group.tfstate.location
  account_tier                    = "Standard"
  account_replication_type        = "GRS" # geo-redundant — state files are critical
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false # never allow public blob access

  blob_properties {
    versioning_enabled = true # recover from accidental state corruption
    delete_retention_policy {
      days = 30
    }
  }
  lifecycle {
    prevent_destroy = true
  }

  tags = azurerm_resource_group.tfstate.tags
}

# One container per Terraform layer — keeps state files isolated
resource "azurerm_storage_container" "layers" {
  for_each = toset([
    "bootstrap",
    "management-groups",
    "policies",
    "connectivity",
    "landing-zones-dev",
    "landing-zones-qa",
    "landing-zones-prod",
    "test-vm",
    "private-endpoints",
    "keyvault",
    "firewall",
    "policies-dine",
    "appgw",

    # ── DR add-on ───────────────────────────────────────────────────────────
    # The azurerm backend does NOT create its container — it expects one to
    # exist and fails at `terraform init` with "container does not exist" if it
    # does not. So every new layer must be listed HERE and bootstrap re-applied
    # BEFORE that layer is ever planned.
    #
    # Bootstrap is not part of terraform-deploy (it creates the backend the
    # pipeline uses), so this is a manual step:
    #   terraform -chdir=infra/platform/bootstrap apply
    #
    # Adding names is safe and additive — prevent_destroy below protects the
    # existing containers, and re-applying does not touch any state file.
    "landing-zones-dr",
    "velero",
    "appgw-dr",
    "frontdoor",
    # Traffic Manager — the global entry point actually in use. Front Door is
    # forbidden on this subscription tier, so its container stays above unused.
    "trafficmanager",
    # Public Azure DNS zone + the app record that points at Traffic Manager.
    "dns",
  ])

  name                  = each.key
  storage_account_name  = azurerm_storage_account.tfstate.name
  container_access_type = "private"

  lifecycle {
    prevent_destroy = true
  }
}
