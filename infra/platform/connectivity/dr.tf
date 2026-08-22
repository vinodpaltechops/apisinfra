# ── DR ADD-ON: second-region AKS private DNS zone ─────────────────────────────
#
# EVERYTHING DR-RELATED IN THIS LAYER LIVES IN THIS ONE FILE. Terraform merges
# all *.tf in a directory, so to go back to the single-region state you comment
# out (or delete) this file and nothing else — main.tf, variables.tf and
# outputs.tf are untouched by the DR work and hold no references to it.
#
# Two ways to switch DR off, in increasing order of finality:
#   1. enable_dr_region = false   → resources destroyed, file stays in place
#   2. comment out this file      → the variables disappear too
# Do (1) and apply BEFORE doing (2): commenting out the file while the zone
# still exists in state orphans it (Terraform stops managing it, Azure keeps
# billing for it).
#
# ── Why a SECOND zone is required ─────────────────────────────────────────────
# The privatelink AKS zone name embeds the CLUSTER's region, not the hub's:
# privatelink.<cluster-region>.azmk8s.io. A cluster in dr_location therefore
# registers its API-server A-record into a different zone than the southindia
# cluster. Pointing the DR cluster at the existing southindia zone produces an
# FQDN nothing ever registers into, and the cluster create fails during
# private-cluster reconcile with the API server unresolvable.
#
# Both zones are linked to the HUB VNet only. Every spoke sets dns_servers to
# the hub resolver inbound IP, so a lookup from any spoke is answered from
# whichever hub-linked zone matches the name — including across regions. That
# is what lets the primary spoke resolve the DR API server without any
# spoke-to-spoke DNS plumbing.

variable "enable_dr_region" {
  description = "Create the DR region's AKS private DNS zone. Set false (and apply) to tear the DR region down while keeping this file in place."
  type        = bool
  default     = true
}

variable "dr_location" {
  description = <<-EOT
    Azure region for the DR AKS cluster. Defaults to centralindia because it is
    southindia's Azure PAIRED region, which matters twice over:

      • a GRS storage account in southindia replicates its secondary INTO
        centralindia, so Velero backups are physically present in the DR region
        (see infra/platform/velero)
      • paired regions are never updated by Azure at the same time

    Change it if your vCPU quota increase lands somewhere else — nothing here
    assumes the pair beyond those two properties.
  EOT
  type        = string
  default     = "centralindia"
}

resource "azurerm_private_dns_zone" "aks_dr" {
  count = var.enable_dr_region ? 1 : 0

  name                = "privatelink.${var.dr_location}.azmk8s.io"
  resource_group_name = azurerm_resource_group.hub.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "aks_dr_hub" {
  count = var.enable_dr_region ? 1 : 0

  name                  = "link-aks-dr-zone-to-hub"
  resource_group_name   = azurerm_resource_group.hub.name
  private_dns_zone_name = azurerm_private_dns_zone.aks_dr[0].name
  virtual_network_id    = module.hub_vnet.vnet_id
  registration_enabled  = false
  tags                  = local.tags
}

# ── Outputs consumed by infra/landing-zones/dr ────────────────────────────────
# null when DR is off, so the DR layer fails loudly ("aks_private_dns_zone_id
# must not be null") rather than silently building a cluster with a broken BYO
# DNS zone.
output "aks_dr_private_dns_zone_id" {
  description = "Pre-created privatelink.<dr_location>.azmk8s.io zone for the DR private AKS cluster (BYO DNS). null when enable_dr_region = false."
  value       = var.enable_dr_region ? azurerm_private_dns_zone.aks_dr[0].id : null
}

output "dr_location" {
  description = "DR region — read by the DR landing zone and the Front Door layer so the region is defined in exactly one place."
  value       = var.dr_location
}
