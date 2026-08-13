# LAYER: APPGW — public entry point for the dev workload
#
# Deployed AFTER landing-zones/dev, because it forwards to that spoke's
# internal ingress load balancer. It does not read the dev state, though: the
# ingress VIP is pinned to a static address in
# k8s/platform/ingress-nginx-values.yaml, so the backend target is a known
# constant rather than an output. That keeps this layer decoupled — it can be
# applied, destroyed and re-applied without touching the landing zone.
#
# The trade-off is that the pin is a convention, not a constraint: change the
# annotation without changing ingress_internal_ip here (or vice versa) and the
# backend pool goes Unhealthy with everything still reporting "Succeeded".
# Both places say so.
#
# Its own state file, per the one-state-per-layer rule — a mistake in the
# public edge must not be able to touch the hub or the spoke.

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
    container_name       = "appgw"
    key                  = "appgw.tfstate"
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
  env = "dev"

  tags = merge(var.common_tags, {
    Layer       = "AppGateway"
    Environment = local.env
    # Required by the "Require CostCenter tag" policy assigned at the org root —
    # a Deny effect, so omitting it fails the apply rather than warning.
    CostCenter = "CloudPlatform"
  })
}

# Hub VNet details come from the connectivity layer (separate state).
data "terraform_remote_state" "connectivity" {
  backend = "azurerm"
  config = {
    resource_group_name  = "rg-tfstate-vinorg-001"
    storage_account_name = "stotfstatevinorg001"
    container_name       = "connectivity"
    key                  = "connectivity.tfstate"
  }
}

module "appgw" {
  source = "../../modules/appgw"

  env                     = local.env
  org_name                = var.org_name
  location                = var.location
  hub_resource_group_name = data.terraform_remote_state.connectivity.outputs.hub_rg_name
  hub_vnet_name           = data.terraform_remote_state.connectivity.outputs.hub_vnet_name

  app_fqdn            = var.app_fqdn
  ingress_internal_ip = var.ingress_internal_ip

  waf_mode                = var.waf_mode
  allowed_source_prefixes = var.allowed_source_prefixes

  # TLS stays off until a certificate exists in Key Vault — see the runbook in
  # docs/public-endpoint.md. Both must be supplied together.
  ssl_certificate_key_vault_secret_id = var.ssl_certificate_key_vault_secret_id
  identity_id                         = var.appgw_identity_id

  tags = local.tags
}
