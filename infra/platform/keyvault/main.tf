# LAYER: KEYVAULT — the dev vault, kept apart so a teardown leaves it alone.
#
# The vault used to live in the dev landing zone, inside the spoke's resource
# group. Destroying dev deleted the resource group and the vault with it —
# taking the TLS certificate (a manual import, and a Let's Encrypt cert is not
# free to reissue) along. It now lives here, in a resource group of its own,
# with its own state, and is DELIBERATELY ABSENT from terraform-destroy.yml.
# Same arrangement as infra/platform/velero, for the same reason.
#
# What stays in the landing zone is the private endpoint: it pins a subnet in
# the spoke, so it has to be created and destroyed with the spoke. The landing
# zone reads this layer's vault ID and builds the endpoint against it.
#
# ── Deploy order ──────────────────────────────────────────────────────────────
# After connectivity (nothing), BEFORE dev: dev reads this layer's state for the
# vault's ID and URI, so it cannot plan until this has been applied.
#
# ── Protection ────────────────────────────────────────────────────────────────
# 1. Not in the destroy pipeline.
# 2. prevent_destroy on the resource group, so `terraform destroy` here fails at
#    plan time, before anything is touched.
# 3. The provider refuses to delete a resource group that still holds resources
#    (prevent_deletion_if_contains_resources, below).
# To remove the vault on purpose: delete the prevent_destroy block, flip that
# provider setting, and destroy by hand. Soft-delete keeps the vault
# recoverable for soft_delete_retention_days; purge protection is off (lab).

terraform {
  required_version = ">= 1.7.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
  backend "azurerm" {
    # resource_group_name + storage_account_name come from infra/backend.json:
    #   terraform init -backend-config=../../backend.json
    container_name = "keyvault"
    # Not "keyvault.tfstate": that container name predates this layer, and a
    # fresh key can never collide with state left in it.
    key = "keyvault-persistent.tfstate"
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
  }
}

locals {
  env = "dev"

  tags = merge(var.common_tags, {
    Layer       = "KeyVault"
    Environment = local.env
    CostCenter  = "CloudPlatform"
    Role        = "Persistent"
  })
}

resource "azurerm_resource_group" "keyvault" {
  name     = "rg-keyvault-${local.env}-${var.org_name}-001"
  location = var.location
  tags     = local.tags

  lifecycle {
    prevent_destroy = true
  }
}

module "keyvault" {
  source = "../../modules/keyvault"

  env                 = local.env
  resource_group_name = azurerm_resource_group.keyvault.name
  location            = var.location
  tags                = local.tags

  # The endpoint is built by the landing zone — see the header.
  create_private_endpoint = false

  # No VM identity any more (mgmt and jump VMs are commented out in dev).
  grant_vm_identity_access = false

  allowed_ip_rules = var.allowed_ip_rules

  # REQUIRED for App Gateway TLS. The gateway reads the certificate from its
  # control plane, which is outside any VNet and so cannot use a private
  # endpoint. This does not open the vault: network_acls keeps
  # default_action = "Deny", so only the AzureServices bypass and
  # allowed_ip_rules get through.
  public_network_access_enabled = var.public_network_access_enabled
}
