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
    Azure region for the DR AKS cluster. indiasouthcentral (Hyderabad).

    ── Why this region ─────────────────────────────────────────────────────────
    Each region carries a default limit of 4 vCPU, and the workload divides into
    exactly 4-vCPU units, so no part of this needs a quota request:

      southindia         hub + dev spoke + dev AKS (2 nodes)   4/4
      centralindia       jump VNet + mgmt VM                   4/4
      indiasouthcentral  DR spoke + DR AKS (2 nodes)           4/4

    It is also genuinely separate infrastructure — Hyderabad, against Chennai
    (southindia) and Pune (centralindia) — and it exposes 3 availability zones,
    which neither of the other two does.

    Note the zero headroom: an AKS node-pool rotation or node-image upgrade
    needs a temporary surge of +2 vCPU, and at 4/4 that surge fails. Raise the
    limit to 6 before attempting either.

    ── What was given up ───────────────────────────────────────────────────────
    indiasouthcentral has NO Azure paired region (`pairedRegion: []`), whereas
    centralindia IS southindia's pair — and the earlier design leaned on that: a
    geo-replicated account in southindia places its secondary in centralindia
    automatically, co-locating backups with the DR cluster.

    Geo-replication itself is unaffected: the Velero storage account lives in
    southindia and its RAGRS secondary still lands in centralindia, whatever
    this variable says. What changed is that the secondary is no longer in the
    SAME region as the DR cluster, so during a southindia outage that cluster
    reads backups from centralindia — one region away rather than local. RA-GRS
    secondary endpoints are globally reachable, so the cost is restore
    bandwidth and latency, not correctness.

    ── Do NOT set this to westindia ────────────────────────────────────────────
    West India cannot run AKS at all: it is absent from
    Microsoft.ContainerService/managedClusters' location list, and
    `az vm list-skus --location westindia` returns ZERO VM SKUs. It nonetheless
    publishes vCPU quota entries (DASv5 limit 4), so quota output alone makes it
    look like a viable, quota-free alternative. It is not.

    ── If you change this again ────────────────────────────────────────────────
    Check the region first — two of these three are easy to assume and wrong:

      az provider show -n Microsoft.ContainerService \
        --query "resourceTypes[?resourceType=='managedClusters'].locations[]" -o tsv
      az vm list-skus --location <r> --size Standard_D2as --resource-type virtualMachines
      az account list-locations --query "[?name=='<r>'].metadata.regionType" -o tsv

    Then add the region to allowed_locations in infra/platform/policies. That
    assignment is a DENY at the org root, so a region missing from it fails the
    apply outright rather than warning.
  EOT
  type        = string
  default     = "indiasouthcentral"
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
