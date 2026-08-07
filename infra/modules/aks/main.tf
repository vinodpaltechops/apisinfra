# MODULE: aks
# Private AKS cluster deployed into the spoke's reserved snet-aks-system /
# snet-aks-user subnets. Azure CNI Overlay, Azure AD + Azure RBAC, private API
# server, OMS agent → hub Log Analytics, Key Vault secrets provider. The jump
# VM's managed identity is granted cluster admin/user so kubectl works from it.
#
# AKS manages its own private DNS zone (private_dns_zone_id = "System") in the
# node resource group; we link that zone to the hub and spoke so the jump VM
# resolves the private API server. The zone name is unique per cluster, so
# dev/qa/prod don't collide.
#
# NOTE: the caller supplies the provider (the dev env root does).

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
  }
}

locals {
  cluster_name = "aks-${var.env}-lab-001"
}

# ── Control-plane user-assigned identity (required for BYO private DNS zone) ───
resource "azurerm_user_assigned_identity" "aks" {
  name                = "id-aks-${var.env}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

# Must exist BEFORE the cluster: lets the control plane create the API-server
# A-record in the hub's pre-created private DNS zone.
resource "azurerm_role_assignment" "aks_dns_contributor" {
  scope                = var.aks_private_dns_zone_id
  role_definition_name = "Private DNS Zone Contributor"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
}

# Creating a VNet link is two-sided: write on the zone (above) PLUS
# virtualNetworks/join/action on the VNet being linked. During private-cluster
# reconcile AKS links the BYO zone to the spoke VNet, so the identity needs
# Network Contributor on the spoke (this also covers joining nodes into the
# spoke's AKS subnets). Without it: LinkedAuthorizationFailed on cluster create.
resource "azurerm_role_assignment" "aks_spoke_network_contributor" {
  scope                = var.spoke_vnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
}

# ── AKS Cluster ────────────────────────────────────────────────────────────────
resource "azurerm_kubernetes_cluster" "this" {
  name                = local.cluster_name
  resource_group_name = var.resource_group_name
  location            = var.location
  dns_prefix          = "aks-${var.env}-lab"
  kubernetes_version  = var.kubernetes_version

  # PRIVATE cluster with a bring-your-own DNS zone (pre-created + hub-linked in
  # the connectivity layer). The BYO zone lets the hub resolver answer the API
  # FQDN during node bootstrap — no System-zone deadlock, no public FQDN needed.
  private_cluster_enabled             = true
  private_cluster_public_fqdn_enabled = false
  private_dns_zone_id                 = var.aks_private_dns_zone_id

  # Enable the OIDC issuer + workload identity so the OIDC output is meaningful.
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # User-assigned identity — required for BYO DNS (it holds Private DNS Zone
  # Contributor on the zone before the cluster is created).
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks.id]
  }

  # ── System node pool — kube-system only ─────────────────────────────────────
  default_node_pool {
    name                         = "system"
    node_count                   = 1
    vm_size                      = var.system_node_vm_size
    vnet_subnet_id               = var.system_subnet_id
    os_disk_size_gb              = 30
    type                         = "VirtualMachineScaleSets"
    only_critical_addons_enabled = true

    # Required to change immutable system-pool properties (e.g. vm_size) on an
    # existing cluster: AKS rotates the pool via a temp pool of this name.
    temporary_name_for_rotation = "systmp"

    node_labels = {
      "nodepool-type" = "system"
      "environment"   = var.env
    }

    tags = var.tags
  }

  # ── Networking — Azure CNI Overlay ──────────────────────────────────────────
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_policy      = "azure"
    pod_cidr            = var.pod_cidr     # overlay — not routable in the VNet
    service_cidr        = var.service_cidr # k8s services range
    dns_service_ip      = var.dns_service_ip
    outbound_type       = "loadBalancer" # lab; enterprise uses userDefinedRouting via firewall
  }

  # ── Azure AD + Azure RBAC ───────────────────────────────────────────────────
  azure_active_directory_role_based_access_control {
    managed                = true # managed AAD — no legacy client/server app IDs needed
    azure_rbac_enabled     = true
    admin_group_object_ids = var.admin_group_object_ids
  }

  local_account_disabled = false # false for lab (easier first kubeconfig)

  # ── Monitoring → hub Log Analytics ──────────────────────────────────────────
  oms_agent {
    log_analytics_workspace_id = var.law_id
  }

  # ── Add-on: Key Vault secrets provider (CSI) ────────────────────────────────
  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "2m"
  }

  tags = var.tags

  # The control-plane identity must hold DNS-zone rights AND spoke-VNet join
  # rights before the cluster is created (BYO private DNS zone reconcile).
  depends_on = [
    azurerm_role_assignment.aks_dns_contributor,
    azurerm_role_assignment.aks_spoke_network_contributor,
  ]
}

# ── User node pool — application workloads ────────────────────────────────────
# ENABLED: this is the 2nd node of the cluster. With the jump VM moved to
# centralindia, southindia's 4 vCPU is fully used by AKS = system node (2) +
# user node (2). So NOTHING else fits in southindia — put extra VMs (e.g. the
# public mgmt VM) in centralindia instead. Comment this out to free 2 vCPU.
resource "azurerm_kubernetes_cluster_node_pool" "user" {
  name                  = "user"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  vm_size               = var.user_node_vm_size
  node_count            = 1
  vnet_subnet_id        = var.user_subnet_id

  node_labels = {
    "nodepool-type" = "user"
    "environment"   = var.env
  }

  tags = var.tags
}

# ── RBAC: jump VM identity can run kubectl against the private cluster ─────────
resource "azurerm_role_assignment" "jump_vm_aks_admin" {
  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = var.jump_vm_principal_id
}

resource "azurerm_role_assignment" "jump_vm_aks_user" {
  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = var.jump_vm_principal_id
}

# ── RBAC: the Terraform operator (you) can run kubectl from your workstation ───
# Azure RBAC for Kubernetes is enabled, so kubectl access needs an Azure role,
# not just the kubeconfig. Set grant_operator_cluster_admin = false once you
# access the cluster through the jump VM instead of your laptop.
data "azurerm_client_config" "current" {}

resource "azurerm_role_assignment" "operator_aks_admin" {
  count                = var.grant_operator_cluster_admin ? 1 : 0
  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = data.azurerm_client_config.current.object_id
}

# ── (PRIVATE-CLUSTER ONLY) Link AKS's auto-created private DNS zone to hub+spoke
# Disabled while the cluster is public. Re-enable together with the private_*
# settings above (and var.hub_vnet_id / var.spoke_vnet_id in variables.tf + the
# dev module-call args) when moving AKS to a private cluster.
# data "azurerm_resources" "aks_private_dns_zone" {
#   resource_group_name = azurerm_kubernetes_cluster.this.node_resource_group
#   type                = "Microsoft.Network/privateDnsZones"
# }
#
# resource "azurerm_private_dns_zone_virtual_network_link" "aks_to_hub" {
#   name                  = "link-aks-${var.env}-dns-to-hub"
#   resource_group_name   = azurerm_kubernetes_cluster.this.node_resource_group
#   private_dns_zone_name = data.azurerm_resources.aks_private_dns_zone.resources[0].name
#   virtual_network_id    = var.hub_vnet_id
#   registration_enabled  = false
# }
#
# resource "azurerm_private_dns_zone_virtual_network_link" "aks_to_spoke" {
#   name                  = "link-aks-${var.env}-dns-to-spoke"
#   resource_group_name   = azurerm_kubernetes_cluster.this.node_resource_group
#   private_dns_zone_name = data.azurerm_resources.aks_private_dns_zone.resources[0].name
#   virtual_network_id    = var.spoke_vnet_id
#   registration_enabled  = false
# }
