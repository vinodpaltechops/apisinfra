# LANDING ZONE: DEV  (single state — landing-zones-dev)
# Composes the whole dev environment from shared modules:
#   spoke-network → test-vm → keyvault → private-endpoints (+ hub peering)
# Wired via module outputs — no cross-component terraform_remote_state.
# qa and prod are identical apart from `env`, `address_space` and the backend.

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
    container_name       = "landing-zones-dev"
    key                  = "landing-zones-dev.tfstate"
  }
}

# One provider for the whole environment. Feature blocks that individual
# components need (VM disk cleanup, Key Vault soft-delete) live here.
provider "azurerm" {
  features {
    virtual_machine {
      delete_os_disk_on_deletion = true
      graceful_shutdown          = false
    }
    key_vault {
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
  }
}

locals {
  env           = "dev"
  address_space = "10.1.0.0/16"

  # Jump VM lives in a different region so it draws on that region's separate
  # vCPU quota — southindia's 4 vCPU is reserved for the 2-node AKS.
  jump_location      = "centralindia"
  jump_address_space = "10.4.0.0/24"

  tags = merge(var.common_tags, {
    Layer       = "LandingZone"
    Environment = local.env
    CostCenter  = "CloudPlatform"
  })

  hub_vnet_id             = data.terraform_remote_state.connectivity.outputs.hub_vnet_id
  hub_vnet_name           = data.terraform_remote_state.connectivity.outputs.hub_vnet_name
  hub_resource_group_name = data.terraform_remote_state.connectivity.outputs.hub_rg_name
  hub_dns_resolver_ip     = data.terraform_remote_state.connectivity.outputs.dns_inbound_ip
  hub_law_id              = data.terraform_remote_state.connectivity.outputs.law_id
  vault_dns_zone_id       = data.terraform_remote_state.connectivity.outputs.vault_private_dns_zone_id
  blob_dns_zone_id        = data.terraform_remote_state.connectivity.outputs.blob_private_dns_zone_id
}

# Hub outputs come from the connectivity platform layer (separate state).
data "terraform_remote_state" "connectivity" {
  backend = "azurerm"
  config = {
    resource_group_name  = "rg-tfstate-vinorg-001"
    storage_account_name = "stotfstatevinorg001"
    container_name       = "connectivity"
    key                  = "connectivity.tfstate"
  }
}

# ── Spoke network: RG + VNet + subnets + NSG + UDR ────────────────────────────
module "spoke_network" {
  source = "../../modules/spoke-network"

  env           = local.env
  org_name      = var.org_name
  location      = var.location
  address_space = local.address_space
  dns_servers   = [local.hub_dns_resolver_ip]
  tags          = local.tags
}

# ── Peering to the hub (both directions) ──────────────────────────────────────
module "peering" {
  source = "../../modules/peering"

  spoke_vnet_name           = module.spoke_network.vnet_name
  spoke_vnet_id             = module.spoke_network.vnet_id
  spoke_resource_group_name = module.spoke_network.resource_group_name
  hub_vnet_name             = local.hub_vnet_name
  hub_vnet_id               = local.hub_vnet_id
  hub_resource_group_name   = local.hub_resource_group_name
  hub_has_gateway           = false

  providers = {
    azurerm.hub   = azurerm
    azurerm.spoke = azurerm
  }
}

# ── Jump network (centralindia) + global peering to the hub ───────────────────
# Separate region = separate vCPU quota. Global peering reaches the hub; DNS
# points at the hub resolver so the jump VM can resolve private zones (ready for
# when AKS/endpoints go fully private).
module "jump_network" {
  source = "../../modules/jump-network"

  env                 = local.env
  resource_group_name = module.spoke_network.resource_group_name
  location            = local.jump_location
  address_space       = local.jump_address_space
  dns_servers         = [local.hub_dns_resolver_ip]
  tags                = local.tags
}

module "peering_jump" {
  source = "../../modules/peering"

  spoke_vnet_name           = module.jump_network.vnet_name
  spoke_vnet_id             = module.jump_network.vnet_id
  spoke_resource_group_name = module.spoke_network.resource_group_name
  hub_vnet_name             = local.hub_vnet_name
  hub_vnet_id               = local.hub_vnet_id
  hub_resource_group_name   = local.hub_resource_group_name
  hub_has_gateway           = false

  providers = {
    azurerm.hub   = azurerm
    azurerm.spoke = azurerm
  }
}

# ── Linux jump VM (in centralindia, reachable over the global peering) ─────────
module "linux_vm" {
  source = "../../modules/linux-vm"

  env                 = local.env
  resource_group_name = module.spoke_network.resource_group_name
  location            = local.jump_location
  subnet_id           = module.jump_network.subnet_id
  tags                = local.tags

  # Bring peering (hub DNS reachability) up before the VM boots so cloud-init
  # can resolve + download via the hub resolver and the jump NAT gateway.
  depends_on = [module.peering_jump]
}

# ── Key Vault (private endpoint, VM identity gets Secrets User) ────────────────
module "keyvault" {
  source = "../../modules/keyvault"

  env                       = local.env
  resource_group_name       = module.spoke_network.resource_group_name
  location                  = var.location
  subnet_id                 = module.spoke_network.data_subnet_id
  vault_private_dns_zone_id = local.vault_dns_zone_id
  vm_identity_principal_id  = module.linux_vm.vm_principal_id
  allowed_ip_rules          = var.allowed_ip_rules
  tags                      = local.tags
}

# ── AKS cluster (private, into the reserved snet-aks-* subnets) ────────────────
module "aks" {
  source = "../../modules/aks"

  env                 = local.env
  location            = var.location
  resource_group_name = module.spoke_network.resource_group_name
  system_subnet_id    = module.spoke_network.subnet_ids["snet-aks-system-${local.env}"]
  user_subnet_id      = module.spoke_network.subnet_ids["snet-aks-user-${local.env}"]
  # hub_vnet_id        = local.hub_vnet_id            # re-enable for private cluster
  # spoke_vnet_id      = module.spoke_network.vnet_id # re-enable for private cluster
  law_id               = local.hub_law_id
  jump_vm_principal_id = module.linux_vm.vm_principal_id
  tags                 = local.tags
}

# ── Storage account behind a private endpoint ─────────────────────────────────
# module "private_endpoints" {
#   source = "../../modules/private-endpoints"

#   env                      = local.env
#   resource_group_name      = module.spoke_network.resource_group_name
#   location                 = var.location
#   subnet_id                = module.spoke_network.app_subnet_id
#   blob_private_dns_zone_id = local.blob_dns_zone_id
#   tags                     = local.tags
# }
