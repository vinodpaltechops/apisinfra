# LAYER: AGC — Application Gateway for Containers, the Gateway API entry point
#
# Deployed AFTER landing-zones/dev: it needs the spoke VNet to place its
# delegated subnet in, and the cluster's OIDC issuer to trust the ALB
# Controller's identity. Both come from the dev state, so unlike the appgw layer
# this one is genuinely coupled to it — applying it before dev fails at plan.
#
# This layer is the Azure half only. The cluster half (ALB Controller Helm
# chart, Gateway + HTTPRoute) is deployed through Argo CD, fed by this layer's
# outputs. nginx and the existing Ingress are not touched.
#
# Its own state file, per the one-state-per-layer rule — destroying the gateway
# must not be able to reach the cluster.

terraform {
  required_version = ">= 1.7.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
  }
  backend "azurerm" {
    # resource_group_name + storage_account_name come from infra/backend.json:
    #   terraform init -backend-config=../../backend.json
    container_name = "agc"
    key            = "agc.tfstate"
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

# Same ARM_* credentials as azurerm; no extra configuration.
provider "azapi" {}

locals {
  env = "dev"

  tags = merge(var.common_tags, {
    Layer       = "ApplicationGatewayForContainers"
    Environment = local.env
    # Required by the "Require CostCenter tag" policy assigned at the org root —
    # a Deny effect, so omitting it fails the apply rather than warning.
    CostCenter = "CloudPlatform"
  })
}

# State storage account + resource group. Same file `terraform init` reads via
# -backend-config, so the name lives in exactly one place.
locals {
  tfstate_backend = jsondecode(file("${path.module}/../../backend.json"))
}

data "terraform_remote_state" "dev" {
  backend = "azurerm"
  config = merge(local.tfstate_backend, {
    container_name = "landing-zones-dev"
    key            = "landing-zones-dev.tfstate"
  })
}

locals {
  dev = data.terraform_remote_state.dev.outputs

  # The dev layer exports the VNet's ID, not its name. A VNet ID is
  # /subscriptions/<s>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<name>,
  # so the name is the 9th "/"-separated segment.
  spoke_vnet_name = element(split("/", local.dev.spoke_vnet_id), 8)
}

module "agc" {
  source = "../../modules/agc"

  env      = local.env
  org_name = var.org_name
  location = var.location

  vnet_name                = local.spoke_vnet_name
  vnet_resource_group_name = local.dev.resource_group_name
  subnet_address_prefix    = var.subnet_address_prefix

  allowed_source_prefixes = var.allowed_source_prefixes

  aks_oidc_issuer_url          = local.dev.aks_oidc_issuer_url
  aks_node_resource_group_name = local.dev.aks_node_resource_group

  tags = local.tags
}
