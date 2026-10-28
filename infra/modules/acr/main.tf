# MODULE: acr
# Azure Container Registry for the application images consumed by the spoke's
# AKS cluster.
#
# SKU = Basic (default): the registry keeps its PUBLIC endpoint. That is a
# deliberate trade-off for this lab — a GitHub-hosted runner has no route into
# the spoke, so a private-endpoint-only registry would need a self-hosted runner
# on the jump VM. The pull path is still identity-based: the AKS kubelet's
# managed identity holds AcrPull, so no imagePullSecret exists anywhere and
# admin credentials stay disabled.
#
# To go fully private later: set sku = "Premium", flip
# public_network_access_enabled to false, add a private endpoint in the spoke's
# data subnet against a privatelink.azurecr.io zone in the hub, and move the
# image build to a self-hosted runner (or an ACR task).

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
  }
}

resource "azurerm_container_registry" "this" {
  name                = var.registry_name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = var.sku

  # Admin user issues a static username/password pair — the exact credential
  # the managed-identity pull path exists to avoid. Keep it off.
  admin_enabled = false

  # Only meaningful on Premium; on Basic the endpoint is public regardless, so
  # this is the switch you flip together with the SKU.
  public_network_access_enabled = var.sku == "Premium" ? var.public_network_access_enabled : true

  # ── DR: geo-replication ─────────────────────────────────────────────────────
  # Empty by default, so this block generates NOTHING and the registry is byte
  # identical to before the DR work. Populating it requires sku = "Premium".
  #
  # Why it matters for DR: a Basic registry lives in ONE region. A DR cluster
  # pointed at it can start images already cached on its nodes, but the moment
  # it needs to pull — a scale-out, a node replacement, a rescheduled pod — it
  # is reaching into the region you are failing away from. That turns the
  # registry into a single point of failure sitting directly on the recovery
  # path, which is the one place it must not be.
  #
  # Geo-replication keeps the login server name identical in every region and
  # routes each pull to the nearest replica automatically, so no manifest,
  # overlay or pipeline changes region.
  dynamic "georeplications" {
    for_each = toset(var.geo_replication_locations)
    content {
      location                = georeplications.value
      zone_redundancy_enabled = false # not available in every region; opt in per region if yours supports it
      tags                    = var.tags
    }
  }

  tags = var.tags
}

# ── Pull: the AKS kubelet identity ────────────────────────────────────────────
# This is what makes `image: <registry>/frontend:tag` work with no pull secret.
# Note the propagation lag: an AcrPull assignment can take a couple of minutes
# to take effect, so the first deploy right after `terraform apply` may show
# ImagePullBackOff briefly before recovering on its own.
resource "azurerm_role_assignment" "kubelet_acr_pull" {
  scope                            = azurerm_container_registry.this.id
  role_definition_name             = "AcrPull"
  principal_id                     = var.kubelet_identity_object_id
  skip_service_principal_aad_check = true # the kubelet identity is an MSI, not an app registration
}

# ── Push: CI, and anything else that needs to publish images ──────────────────
# The deploy service principal already holds Owner at the root management group,
# which covers ACR push. This variable exists for principals that do NOT — e.g.
# a scoped-down build identity, or the jump VM if you build images on it.
# Keyed by the map's static labels — see the variable's docs for why not the IDs.
resource "azurerm_role_assignment" "acr_push" {
  for_each = var.push_principals

  scope                            = azurerm_container_registry.this.id
  role_definition_name             = "AcrPush"
  principal_id                     = each.value
  skip_service_principal_aad_check = true
}
