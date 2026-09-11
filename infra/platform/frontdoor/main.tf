# LAYER: FRONTDOOR — the global entry point that makes two regions one service.
#
# Deployed LAST, after both App Gateways: it needs their public IPs as origins.
#
# ── The DNS cutover ───────────────────────────────────────────────────────────
# Today app.<domain> is an A record pointing at the primary gateway's IP. Front
# Door replaces that with a CNAME to the *.azurefd.net endpoint. Until that
# record is changed, this layer is inert — it costs money and serves nobody, and
# the existing single-region path keeps working untouched. That makes the
# cutover a reversible, one-record decision, which is exactly what you want for
# the only thing standing between users and the app.
#
# Run `terraform output dns_records` for the two records to create, in order.
#
# ── Removing DR / Front Door ──────────────────────────────────────────────────
# Point app.<domain> back at the primary gateway's A record, then destroy this
# layer. Do it in THAT order: destroying first leaves the CNAME resolving to a
# deleted endpoint, which is a hard outage rather than a graceful fallback.

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
    container_name = "frontdoor"
    key            = "frontdoor.tfstate"
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
    Layer      = "FrontDoor"
    CostCenter = "CloudPlatform"
    Role       = "DisasterRecovery"
  })

  # Origins are assembled from the two App Gateway layers' states rather than
  # typed as literals: a gateway rebuild changes its public IP, and a stale
  # literal here sends every request to an address Azure has since handed to
  # someone else.
  #
  # Static keys ("primary"/"dr"); only the values are apply-time unknowns.
  origins = merge(
    {
      primary = {
        host_name = data.terraform_remote_state.appgw.outputs.appgw_public_ip
        priority  = 1 # takes ALL traffic while healthy
        enabled   = true
      }
    },
    var.enable_dr_origin ? {
      dr = {
        host_name = data.terraform_remote_state.appgw_dr[0].outputs.appgw_public_ip
        priority  = 2 # standby — receives traffic only when priority 1 fails its probe
        enabled   = true
      }
    } : {},
  )
}

# State storage account + resource group. Same file `terraform init` reads via
# -backend-config, so the name lives in exactly one place.
locals {
  tfstate_backend = jsondecode(file("${path.module}/../../backend.json"))
}

data "terraform_remote_state" "appgw" {
  backend = "azurerm"
  config = merge(local.tfstate_backend, {
    container_name = "appgw"
    key            = "appgw.tfstate"
  })
}

# count, so this layer can be applied before the DR region exists — an
# unconditional read of a state file that has never been written fails at plan.
data "terraform_remote_state" "appgw_dr" {
  count = var.enable_dr_origin ? 1 : 0

  backend = "azurerm"
  config = merge(local.tfstate_backend, {
    container_name = "appgw-dr"
    key            = "appgw-dr.tfstate"
  })
}

# Front Door is global; this group only holds its metadata.
resource "azurerm_resource_group" "frontdoor" {
  name     = "rg-frontdoor-${var.org_name}-001"
  location = var.location
  tags     = local.tags
}

module "frontdoor" {
  source = "../../modules/frontdoor"

  org_name            = var.org_name
  resource_group_name = azurerm_resource_group.frontdoor.name
  app_fqdn            = var.app_fqdn
  sku_name            = var.sku_name

  origins = local.origins

  health_probe_path             = var.health_probe_path
  health_probe_protocol         = var.health_probe_protocol
  health_probe_interval_seconds = var.health_probe_interval_seconds
  forwarding_protocol           = var.forwarding_protocol

  tags = local.tags
}
