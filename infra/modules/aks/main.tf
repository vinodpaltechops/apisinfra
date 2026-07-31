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

# ── AKS Cluster ────────────────────────────────────────────────────────────────
resource "azurerm_kubernetes_cluster" "this" {
  name                = local.cluster_name
  resource_group_name = var.resource_group_name
  location            = var.location
  dns_prefix          = "aks-${var.env}-lab"
  kubernetes_version  = var.kubernetes_version

  # Public API server. A PRIVATE cluster + the hub DNS resolver can't self-resolve
  # the API server during node bootstrap: AKS's "System" private DNS zone links
  # only to the spoke, but nodes query the hub resolver, which isn't linked to
  # that zone until after creation — a deadlock. Kept public for the lab.
  private_cluster_enabled = false
  # To move to a PRIVATE cluster later: set the line above to true, uncomment
  # these, and uncomment the DNS-zone links near the bottom of this file.
  # private_cluster_public_fqdn_enabled = true
  # private_dns_zone_id                 = "System"

  # Enable the OIDC issuer + workload identity so the OIDC output is meaningful.
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  identity {
    type = "SystemAssigned"
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
}

# ── User node pool — application workloads ────────────────────────────────────
# DISABLED to fit the 4-vCPU regional quota (system node + jump VM already use
# all 4). Re-enable once the quota is raised — nothing else needs to change; it
# still references var.user_node_vm_size / var.user_subnet_id (kept declared).
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
