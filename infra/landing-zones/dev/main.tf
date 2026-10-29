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
    # resource_group_name + storage_account_name come from infra/backend.json:
    #   terraform init -backend-config=../../backend.json
    container_name = "landing-zones-dev"
    key            = "landing-zones-dev.tfstate"
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
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

locals {
  env           = "dev"
  address_space = "10.1.0.0/16"

  # Azure CNI Overlay pod CIDR. Single source of truth: the AKS module needs it
  # to configure the overlay, and the spoke NSG needs it to permit cross-node
  # pod traffic (see the spoke-network module's aks_pod_cidr variable — without
  # that rule, deny-all-inbound breaks cluster DNS). Not routable in the VNet,
  # so it must not overlap any spoke/hub address space.
  aks_pod_cidr = "192.168.0.0/16"

  # The jump VNet predates the move of the dev spoke to centralindia (needed
  # because Application Gateway for Containers is not offered in southindia).
  # With every VM commented out it is an empty network now; kept so the VMs can
  # come back, and because removing it is a separate change.
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
  aks_dns_zone_id         = data.terraform_remote_state.connectivity.outputs.aks_private_dns_zone_id
}

# State storage account + resource group. Same file `terraform init` reads via
# -backend-config, so the name lives in exactly one place.
locals {
  tfstate_backend = jsondecode(file("${path.module}/../../backend.json"))
}

# Hub outputs come from the connectivity platform layer (separate state).
data "terraform_remote_state" "connectivity" {
  backend = "azurerm"
  config = merge(local.tfstate_backend, {
    container_name = "connectivity"
    key            = "connectivity.tfstate"
  })
}

# ── Spoke network: RG + VNet + subnets + NSG + UDR ────────────────────────────
module "spoke_network" {
  source = "../../modules/spoke-network"

  env           = local.env
  org_name      = var.org_name
  location      = var.location
  address_space = local.address_space
  dns_servers   = [local.hub_dns_resolver_ip]
  # Allow the jump VNet (its own region/address space) into the spoke so it can
  # reach the AKS + Key Vault private endpoints. NSG is enforced on the PE subnets.
  mgmt_address_spaces = [local.jump_address_space]
  # Required for the AKS cluster below: opens the NSG to overlay pod IPs so
  # cross-node pod traffic (including DNS to CoreDNS) is not denied.
  aks_pod_cidr = local.aks_pod_cidr
  tags         = local.tags
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
# module "linux_vm" {
#   source = "../../modules/linux-vm"

#   env                 = local.env
#   resource_group_name = module.spoke_network.resource_group_name
#   location            = local.jump_location
#   subnet_id           = module.jump_network.subnet_id
#   ssh_public_key      = var.ssh_public_key
#   tags                = local.tags

#   # Bring peering (hub DNS reachability) up before the VM boots so cloud-init
#   # can resolve + download via the hub resolver and the jump NAT gateway.
#   depends_on = [module.peering_jump]
# }

# ── Public mgmt VM (bastion replacement) — centralindia, same jump VNet ────────
# Free-tier substitute for Azure Bastion. Lives in centralindia because
# southindia's 4 vCPU is fully used by the 2-node AKS; centralindia has room
# (jump 2 + mgmt 2 = 4/4). Public SSH (locked to your IP via a NIC-level NSG);
# from here `ssh -A azureadmin@<jump-private-ip>` to reach the private jump VM,
# or test the private endpoints directly (jump VNet is peered to hub + spoke and
# uses the hub resolver for DNS).
#
# DISABLED for the AGC work (feat/agc-centralindia): the dev spoke and AKS now
# live in centralindia, and the cluster's API server is public (restricted to
# aks_authorized_ip_ranges), so kubectl runs from the laptop and this VM's 2
# vCPU go to the cluster instead. Re-enable together with its references in
# module "keyvault", module "aks" and outputs.tf, or `terraform validate` fails
# with "Reference to undeclared module".
# module "linux_vm_mgmt" {
#   source = "../../modules/linux-vm"
#
#   env                 = local.env
#   role                = "mgmt"
#   resource_group_name = module.spoke_network.resource_group_name
#   location            = local.jump_location
#   subnet_id           = module.jump_network.subnet_id
#   enable_public_ip    = true
#   ssh_source_prefix   = var.mgmt_ssh_source_prefix
#   ssh_public_key      = var.ssh_public_key
#   tags                = local.tags
#
#   depends_on = [module.peering_jump]
# }

# ── Global peering: jump VNet ↔ dev spoke (data path to the private AKS API) ──
# Peering is non-transitive, so jump↔hub alone can't reach the API server's
# private endpoint (which lives in the dev spoke). This direct peering gives the
# jump VM a route to it. DNS still resolves via the hub resolver (jump↔hub).
resource "azurerm_virtual_network_peering" "jump_to_spoke" {
  name                         = "peer-jump-to-dev-spoke"
  resource_group_name          = module.spoke_network.resource_group_name
  virtual_network_name         = module.jump_network.vnet_name
  remote_virtual_network_id    = module.spoke_network.vnet_id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

resource "azurerm_virtual_network_peering" "spoke_to_jump" {
  name                         = "peer-dev-spoke-to-jump"
  resource_group_name          = module.spoke_network.resource_group_name
  virtual_network_name         = module.spoke_network.vnet_name
  remote_virtual_network_id    = module.jump_network.vnet_id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

# ── Key Vault — lives in platform/keyvault, only the private endpoint is here ───
# The vault itself (and so the TLS certificate in it) must survive a teardown, so
# it has its own resource group, state and deploy slot, and is absent from the
# destroy pipeline. This landing zone keeps just the private endpoint, because it
# pins a subnet in this spoke and so has to be destroyed with it.
#
# Needs platform/keyvault applied first; terraform-deploy.yml orders it before
# dev.
data "terraform_remote_state" "keyvault" {
  backend = "azurerm"
  config = merge(local.tfstate_backend, {
    container_name = "keyvault"
    key            = "keyvault-persistent.tfstate"
  })
}

resource "azurerm_private_endpoint" "keyvault" {
  name                = "pe-keyvault-${local.env}"
  resource_group_name = module.spoke_network.resource_group_name
  location            = var.location
  subnet_id           = module.spoke_network.data_subnet_id

  private_service_connection {
    name                           = "psc-keyvault-${local.env}"
    private_connection_resource_id = data.terraform_remote_state.keyvault.outputs.key_vault_id
    is_manual_connection           = false
    subresource_names              = ["vault"]
  }

  private_dns_zone_group {
    name                 = "pdz-group-vault"
    private_dns_zone_ids = [local.vault_dns_zone_id]
  }

  tags = local.tags
}

# ── AKS cluster (private, into the reserved snet-aks-* subnets) ────────────────
module "aks" {
  source = "../../modules/aks"

  env                 = local.env
  location            = var.location
  resource_group_name = module.spoke_network.resource_group_name
  system_subnet_id    = module.spoke_network.subnet_ids["snet-aks-system-${local.env}"]
  user_subnet_id      = module.spoke_network.subnet_ids["snet-aks-user-${local.env}"]
  spoke_vnet_id       = module.spoke_network.vnet_id
  law_id              = local.hub_law_id
  # jump_vm_principal_id is omitted (null) while module "linux_vm" is commented
  # out. Do not point it at the mgmt VM — that principal is already granted the
  # same two roles via additional_admin_principals below, and a second
  # assignment at the same scope fails with RoleAssignmentExists.
  # jump_vm_principal_id  = module.linux_vm.vm_principal_id
  pod_cidr = local.aks_pod_cidr # same value the spoke NSG allows
  tags     = local.tags

  # PUBLIC API server so kubectl works from the laptop (the private cluster was
  # only reachable from the mgmt VM). No BYO private DNS zone is used, so
  # local.aks_dns_zone_id (a southindia zone anyway) is deliberately not passed.
  # Sign-in is still Entra ID + Azure RBAC; the IP list narrows who can even try.
  private_cluster_enabled         = false
  api_server_authorized_ip_ranges = var.aks_authorized_ip_ranges

  # The pipelines use `az aks command invoke`, which does not depend on the
  # authorized ranges above. The mgmt VM's cluster-admin grant went with it.
  # additional_admin_principals = { mgmt_vm = module.linux_vm_mgmt.vm_principal_id }

  grant_operator_cluster_admin = true # lab: allow kubectl from your workstation
}

# ── Container registry for the application images ─────────────────────────────
# Lives in the landing zone (not the platform) because the images it holds are
# workload artefacts, and its only consumer is this spoke's cluster. Basic SKU
# = public endpoint; see the module header for the trade-off and the path to a
# private-endpoint Premium registry.
module "acr" {
  source = "../../modules/acr"

  registry_name              = var.acr_name
  resource_group_name        = module.spoke_network.resource_group_name
  location                   = var.location
  sku                        = var.acr_sku
  kubelet_identity_object_id = module.aks.kubelet_identity
  tags                       = local.tags

  # Empty by default — no geo-replication, registry unchanged. Populate it (and
  # move acr_sku to "Premium") only if you want the DR region to pull from a
  # local replica instead of reaching back into southindia. See
  # dev.auto.tfvars for the switch and the cost note.
  geo_replication_locations = var.acr_geo_replication_locations
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
