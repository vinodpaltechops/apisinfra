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

  # Targets are read from the gateway layers' states rather than typed as
  # literals: a rebuild changes the address, and a stale literal here sends every
  # user to a name Azure has since handed to someone else.
  #
  # Two live entrances, for the SAME hostname, and the endpoint that actually
  # serves the app wins on its own:
  #
  #   appgw    App Gateway -> internal ingress-nginx.  Probed on the APP's hostname,
  #            so it reads Online only while an nginx app answers there.
  #   primary  the AGC frontend (a HOSTNAME, not an IP: AGC exposes no public
  #            address, and an external endpoint accepts either). Probed on the
  #            platform health host, so it reads Online whenever the gateway is up,
  #            app or no app.
  #
  # That asymmetry is why the order matters. AGC is always Online, so if it ranked
  # first it would take every query even when the app is only deployed behind
  # nginx, and the App Gateway would never be asked. App Gateway first means: app
  # on nginx -> it is Online -> it wins; app on AGC -> it is Degraded -> AGC
  # answers. Content Hub's two variants cannot run together, so exactly one holds.
  #
  # This is a limit, not a feature: the App Gateway listener is bound to ONE
  # hostname (app_fqdn), so it can only ever front the same name AGC serves.
  #
  # The DR endpoint is still the DR App Gateway's IP until DR moves to AGC too.
  #
  # Static keys ("appgw"/"primary"/"dr"); only the values are apply-time unknowns.
  endpoints = merge(
    var.enable_appgw_endpoint ? {
      appgw = {
        target            = data.terraform_remote_state.appgw[0].outputs.appgw_public_ip
        priority          = var.appgw_priority
        location          = var.primary_location
        enabled           = true
        probe_host_header = var.app_fqdn
      }
    } : {},
    {
      primary = {
        target   = data.terraform_remote_state.agc.outputs.frontend_fqdn
        priority = var.agc_priority
        location = var.primary_location
        enabled  = true
        # no override: inherits the profile's platform health host
      }
    },
    var.enable_dr_endpoint ? {
      dr = {
        target   = data.terraform_remote_state.appgw_dr[0].outputs.appgw_public_ip
        priority = var.dr_priority # last resort — answers only when everything above fails its probe
        location = var.dr_location
        enabled  = true
      }
    } : {},
  )
}

data "terraform_remote_state" "agc" {
  backend = "azurerm"
  config = merge(local.tfstate_backend, {
    container_name = "agc"
    key            = "agc.tfstate"
  })
}

# count, so this layer can run without the App Gateway layer — an unconditional
# read of a state file that was never written fails at plan, and that layer is
# optional (terraform-deploy.yml, job appgw).
data "terraform_remote_state" "appgw" {
  count = var.enable_appgw_endpoint ? 1 : 0

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

  # Probes carry the PLATFORM health hostname, not an app's. The gateway routes
  # by host, so the probe must name a host that has a route; that route is the
  # platform-owned health responder (k8s/gitops/platform/agc-gateway), so the
  # endpoint's health no longer depends on any application being deployed. The
  # chart's health.hostname must match. See modules/trafficmanager/main.tf.
  probe_host_header = var.health_hostname

  ttl                           = var.ttl
  health_probe_path             = var.health_probe_path
  health_probe_protocol         = var.health_probe_protocol
  health_probe_port             = var.health_probe_port
  health_probe_interval_seconds = var.health_probe_interval_seconds
  tolerated_number_of_failures  = var.tolerated_number_of_failures

  tags = local.tags
}
