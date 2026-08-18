# MODULE: peering
# Creates BOTH sides of a VNet peering in one module call.
# This prevents the common mistake of creating only one side.
# Both sides must exist simultaneously — if one is deleted, traffic stops.


resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  name                      = "peer-${var.spoke_vnet_name}-to-hub"
  resource_group_name       = var.spoke_resource_group_name
  virtual_network_name      = var.spoke_vnet_name
  remote_virtual_network_id = var.hub_vnet_id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  # use_remote_gateways: set true ONLY if Hub has a VPN/ER Gateway deployed.
  # Setting true when no gateway exists causes a permanent error.
  use_remote_gateways = var.hub_has_gateway

  # Provider alias — spoke side may be in a different subscription
  provider = azurerm.spoke
}

resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  name                      = "peer-hub-to-${var.spoke_vnet_name}"
  resource_group_name       = var.hub_resource_group_name
  virtual_network_name      = var.hub_vnet_name
  remote_virtual_network_id = var.spoke_vnet_id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = var.hub_has_gateway # share Hub gateway to spokes

  provider = azurerm.hub

  # MUST be sequential, not parallel. Nothing in the configuration links these
  # two resources, so Terraform would otherwise create both at once — and Azure
  # cannot process concurrent peering writes across the same VNet pair. One
  # side then fails with:
  #
  #   ReferencedResourceNotProvisioned: Cannot proceed with operation because
  #   resource .../virtualNetworks/vnet-spoke-dev-001 is not in Succeeded state
  #
  # It is a race, so it only fails sometimes — which is worse than always
  # failing, because a half-built peering looks fine until something needs it.
  #
  # The consequence is not subtle: the surviving side sits in "Initiated"
  # instead of "Connected" and carries NO traffic. Spoke workloads then cannot
  # reach the hub DNS resolver, so a private AKS node cannot resolve anything
  # during bootstrap and its vmssCSE extension dies with ExitCode 50
  # (ERR_OUTBOUND_CONN_FAIL) — after the cluster has spent ~45 minutes in
  # "Creating". The symptom is nowhere near the cause.
  depends_on = [azurerm_virtual_network_peering.spoke_to_hub]
}
