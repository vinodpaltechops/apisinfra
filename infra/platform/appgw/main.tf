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
    # resource_group_name + storage_account_name come from infra/backend.json:
    #   terraform init -backend-config=../../backend.json
    container_name = "appgw"
    key            = "appgw.tfstate"
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

# State storage account + resource group. Same file `terraform init` reads via
# -backend-config, so the name lives in exactly one place.
locals {
  tfstate_backend = jsondecode(file("${path.module}/../../backend.json"))
}

# Hub VNet details come from the connectivity layer (separate state).
data "terraform_remote_state" "connectivity" {
  backend = "azurerm"
  config = merge(local.tfstate_backend, {
    container_name = "connectivity"
    key            = "connectivity.tfstate"
  })
}

# The vault is created by the dev landing zone with a random name suffix, so its
# URI and resource ID are read from that state rather than typed. try() keeps
# this layer plannable before dev has been re-applied with the key_vault_id
# output; the gateway module then reports the missing certificate source itself.
data "terraform_remote_state" "dev" {
  backend = "azurerm"
  config = merge(local.tfstate_backend, {
    container_name = "landing-zones-dev"
    key            = "landing-zones-dev.tfstate"
  })
}

locals {
  dev_key_vault_id  = try(data.terraform_remote_state.dev.outputs.key_vault_id, null)
  dev_key_vault_uri = try(data.terraform_remote_state.dev.outputs.key_vault_uri, null)

  # Explicit variables win; otherwise the certificate comes from dev's vault,
  # unless a PFX was supplied (a second source would fail the module's check).
  use_vault_cert = var.enable_https && var.ssl_certificate_pfx_path == null

  key_vault_id = local.use_vault_cert ? coalesce(var.key_vault_id, local.dev_key_vault_id) : null

  # UNVERSIONED secret URL, so the gateway follows rotations by itself.
  ssl_certificate_key_vault_secret_id = local.use_vault_cert ? coalesce(
    var.ssl_certificate_key_vault_secret_id,
    local.dev_key_vault_uri == null ? null : "${trimsuffix(local.dev_key_vault_uri, "/")}/secrets/${var.ssl_certificate_secret_name}",
  ) : null
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

  # ── DR: origin lock ─────────────────────────────────────────────────────────
  # null by default, which generates no WAF custom rule and leaves this gateway
  # exactly as it is today — the public entry point, reachable on its own IP.
  #
  # Set it (from the frontdoor layer's frontdoor_id output) once Front Door
  # fronts this gateway, so the WAF drops anything arriving without the matching
  # X-Azure-FDID header. Setting it BEFORE Front Door exists blocks all traffic.
  frontdoor_id = var.frontdoor_id

  # ── TLS ─────────────────────────────────────────────────────────────────────
  # enable_https = false → :80 serves the app. A complete configuration, not a
  #                        half-built one; the gateway needs no certificate.
  # enable_https = true  → :443 serves it, and :80 either redirects there or
  #                        keeps serving too (http_redirect_to_https).
  #
  # Flipping this only adds/removes listeners and routing rules on the existing
  # gateway. The public IP is untouched, so the GoDaddy A record stays valid
  # either way.
  enable_https           = var.enable_https
  http_redirect_to_https = var.http_redirect_to_https

  # Certificate source — exactly one when enable_https = true.
  # The module creates its own managed identity and grants it Key Vault Secrets
  # User, so there is no manual `az identity create` / `az role assignment`.
  # Getting the certificate INTO the vault stays a manual step (see
  # docs/public-endpoint.md) — no Terraform resource can complete a CA's domain
  # ownership challenge.
  ssl_certificate_key_vault_secret_id = local.ssl_certificate_key_vault_secret_id
  key_vault_id                        = local.key_vault_id

  ssl_certificate_pfx_path     = var.ssl_certificate_pfx_path
  ssl_certificate_pfx_password = var.ssl_certificate_pfx_password

  tags = local.tags
}
