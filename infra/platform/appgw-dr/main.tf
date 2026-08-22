# LAYER: APPGW-DR — the DR region's public entry point.
#
# Same module, same shape, same certificate as infra/platform/appgw. Three
# differences, all forced by geography:
#
#   1. It lives in the DR SPOKE's VNet, not the hub. An Application Gateway
#      needs a subnet in its OWN region, and the hub VNet is in southindia — a
#      gateway in indiasouthcentral simply cannot use a subnet there. The dev
#      gateway sits in the hub because that is where its region's shared
#      network is; this one sits in the DR spoke for the same reason.
#
#   2. It forwards to 10.5.2.250, the DR cluster's internal ingress VIP.
#
#   3. Its NSG admits AzureFrontDoor.Backend rather than the whole Internet,
#      because Front Door is the only thing that should ever reach it.
#
# ── Naming note ───────────────────────────────────────────────────────────────
# The module's inputs are still called hub_resource_group_name / hub_vnet_name.
# They mean "the resource group and VNet to place the gateway in" and were named
# when the hub was the only answer. Passing DR spoke values is correct; the
# variables were deliberately NOT renamed, so that the existing, working appgw
# layer needs no edit as part of the DR work.
#
# ── Removing DR ───────────────────────────────────────────────────────────────
# Destroy this layer and drop the `dr` entry from the frontdoor layer's origins.
# The public endpoint keeps serving from the primary throughout.

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
    container_name       = "appgw-dr"
    key                  = "appgw-dr.tfstate"
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
  env = "dr"

  tags = merge(var.common_tags, {
    Layer       = "AppGateway"
    Environment = local.env
    CostCenter  = "CloudPlatform" # Deny-effect policy at the org root requires this
    Role        = "DisasterRecovery"
  })
}

# Unlike the primary appgw layer — which deliberately avoids reading dev's state
# and pins the ingress VIP as a constant — this layer DOES read the DR landing
# zone. It needs the spoke's resource group, VNet name and region, none of which
# are constants, and all of which come from one place there.
data "terraform_remote_state" "dr" {
  backend = "azurerm"
  config = {
    resource_group_name  = "rg-tfstate-vinorg-001"
    storage_account_name = "stotfstatevinorg001"
    container_name       = "landing-zones-dr"
    key                  = "landing-zones-dr.tfstate"
  }
}

module "appgw" {
  source = "../../modules/appgw"

  env      = local.env
  org_name = var.org_name

  # DR spoke, not the hub — see the naming note in the header.
  location                = data.terraform_remote_state.dr.outputs.location
  hub_resource_group_name = data.terraform_remote_state.dr.outputs.resource_group_name
  hub_vnet_name           = "vnet-spoke-dr-001"
  subnet_address_prefix   = var.subnet_address_prefix

  app_fqdn = var.app_fqdn

  # The DR cluster's internal ingress VIP, from the landing zone rather than
  # re-typed here — the primary layer pins its equivalent as a literal, and
  # keeping the two in sync by hand is exactly the failure mode that pinning
  # invites.
  ingress_internal_ip = data.terraform_remote_state.dr.outputs.ingress_internal_ip

  waf_mode = var.waf_mode

  # Front Door is the ONLY legitimate source. The service tag is a coarse
  # filter — it admits every Front Door profile in Azure, not just ours — so it
  # is the NSG half of the lock only; the precise half is frontdoor_id below,
  # which makes the WAF check the X-Azure-FDID header.
  allowed_source_prefixes = var.allowed_source_prefixes

  # ── Chicken and egg ─────────────────────────────────────────────────────────
  # Front Door needs this gateway's public IP; this gateway needs Front Door's
  # GUID. Two passes, in this order:
  #   1. apply this layer with frontdoor_id = null  (gateway exists, IP known)
  #   2. apply the frontdoor layer                  (GUID known)
  #   3. set frontdoor_id in appgw-dr.auto.tfvars and re-apply this layer
  # Setting it in pass 1 blocks all traffic, including Front Door's own health
  # probes, so the origin never comes up healthy.
  frontdoor_id = var.frontdoor_id

  # ── TLS: the SAME certificate as the primary gateway ────────────────────────
  # Both gateways serve app_fqdn, so both need a certificate for it. Sharing the
  # dev spoke's vault rather than copying the cert into a second one means one
  # renewal, not two — and a certificate that expires in only one region is a
  # failure that stays invisible until you fail over.
  #
  # The vault is private, but keeps public_network_access_enabled = true with
  # default_action = Deny and the AzureServices bypass. That bypass is not
  # region-scoped, so this gateway's control plane reads it exactly as the
  # primary's does. The module creates this gateway's own identity and grants it
  # Key Vault Secrets User — a second, separate assignment from the primary's.
  enable_https                        = var.enable_https
  http_redirect_to_https              = var.http_redirect_to_https
  ssl_certificate_key_vault_secret_id = var.ssl_certificate_key_vault_secret_id
  key_vault_id                        = var.key_vault_id

  tags = local.tags
}
