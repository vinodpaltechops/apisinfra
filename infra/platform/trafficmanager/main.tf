# LAYER: TRAFFICMANAGER — the global entry point that makes two regions one
# service, on a subscription that cannot have Front Door.
#
# Deployed LAST, after both App Gateways: it needs their public IPs as targets.
#
# ── Why this layer exists at all ──────────────────────────────────────────────
# infra/platform/frontdoor is the better design and is kept intact, unapplied.
# Azure refuses Front Door on Free Trial and Student subscriptions:
#
#   Code="BadRequest" Message="Free Trial and Student account is forbidden
#   for Azure Frontdoor resources."
#
# Traffic Manager has no such restriction. It is a weaker instrument — DNS
# rather than a proxy, see the long note in modules/trafficmanager — but it is
# the difference between automatic failover and a human editing a DNS record
# during an incident. Run ONE of the two, never both: two systems owning
# app_fqdn's failover is how a "failover" ends up pointing at a dead region.
#
# ── The DNS cutover ───────────────────────────────────────────────────────────
# Today app.<domain> is an A record pointing at the primary gateway's IP.
# Traffic Manager replaces it with a CNAME to *.trafficmanager.net. Until that
# record changes, this layer is inert — it costs a couple of dollars and serves
# nobody, and the existing single-region path keeps working untouched. That
# makes the cutover a reversible, one-record decision, which is what you want
# for the only thing standing between users and the app.
#
# Run `terraform output dns_records` for the exact record.
#
# ── Removing it ───────────────────────────────────────────────────────────────
# Point app.<domain> back at the primary gateway's A record, then destroy this
# layer. In THAT order: destroying first leaves the CNAME resolving to a deleted
# profile, which is a hard outage rather than a graceful fallback.

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
    container_name = "trafficmanager"
    key            = "trafficmanager.tfstate"
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

# State storage account + resource group. Same file `terraform init` reads via
# -backend-config, so the name lives in exactly one place.
locals {
  tfstate_backend = jsondecode(file("${path.module}/../../backend.json"))
}

locals {
  tags = merge(var.common_tags, {
    Layer      = "TrafficManager"
    CostCenter = "CloudPlatform"
    Role       = "DisasterRecovery"
  })

  # Targets are assembled from the two App Gateway layers' states rather than
  # typed as literals: a gateway rebuild changes its public IP, and a stale
  # literal here sends every user to an address Azure has since handed to
  # someone else.
  #
  # Static keys ("primary"/"dr"); only the values are apply-time unknowns.
  endpoints = merge(
    {
      primary = {
        target   = data.terraform_remote_state.appgw.outputs.appgw_public_ip
        priority = 1 # takes ALL traffic while healthy
        location = var.primary_location
        enabled  = true
      }
    },
    var.enable_dr_endpoint ? {
      dr = {
        target   = data.terraform_remote_state.appgw_dr[0].outputs.appgw_public_ip
        priority = 2 # standby — answers queries only when priority 1 fails its probe
        location = var.dr_location
        enabled  = true
      }
    } : {},
  )
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
  count = var.enable_dr_endpoint ? 1 : 0

  backend = "azurerm"
  config = merge(local.tfstate_backend, {
    container_name = "appgw-dr"
    key            = "appgw-dr.tfstate"
  })
}

# Traffic Manager is global; this group only holds its metadata.
resource "azurerm_resource_group" "trafficmanager" {
  name     = "rg-trafficmanager-${var.org_name}-001"
  location = var.location
  tags     = local.tags
}

module "trafficmanager" {
  source = "../../modules/trafficmanager"

  org_name            = var.org_name
  resource_group_name = azurerm_resource_group.trafficmanager.name

  endpoints = local.endpoints

  # The gateways listen host-based, so probes MUST carry the app's FQDN or they
  # 404 and degrade every endpoint. See modules/trafficmanager/main.tf.
  probe_host_header = var.app_fqdn

  ttl                           = var.ttl
  health_probe_path             = var.health_probe_path
  health_probe_protocol         = var.health_probe_protocol
  health_probe_port             = var.health_probe_port
  health_probe_interval_seconds = var.health_probe_interval_seconds
  tolerated_number_of_failures  = var.tolerated_number_of_failures

  tags = local.tags
}
