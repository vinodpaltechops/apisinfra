# LANDING ZONE: QA  (single state — landing-zones-qa)
# Identical to dev apart from `env`, `address_space` and the backend container.
# See landing-zones/dev/main.tf for the fully-commented version.
# The privatelink DNS zones are centralized in the connectivity (hub) layer, so
# every environment can be applied independently with no DNS conflicts.

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
    container_name = "landing-zones-qa"
    key            = "landing-zones-qa.tfstate"
  }
}

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
  env           = "qa"
  address_space = "10.2.0.0/16"

  tags = merge(var.common_tags, {
    Layer       = "LandingZone"
    Environment = local.env
    CostCenter  = "CloudPlatform"
  })

  hub_vnet_id             = data.terraform_remote_state.connectivity.outputs.hub_vnet_id
  hub_vnet_name           = data.terraform_remote_state.connectivity.outputs.hub_vnet_name
  hub_resource_group_name = data.terraform_remote_state.connectivity.outputs.hub_rg_name
  hub_dns_resolver_ip     = data.terraform_remote_state.connectivity.outputs.dns_inbound_ip
  vault_dns_zone_id       = data.terraform_remote_state.connectivity.outputs.vault_private_dns_zone_id
  blob_dns_zone_id        = data.terraform_remote_state.connectivity.outputs.blob_private_dns_zone_id
}

# State storage account + resource group. Same file `terraform init` reads via
# -backend-config, so the name lives in exactly one place.
locals {
  tfstate_backend = jsondecode(file("${path.module}/../../backend.json"))
}

data "terraform_remote_state" "connectivity" {
  backend = "azurerm"
  config = merge(local.tfstate_backend, {
    container_name = "connectivity"
    key            = "connectivity.tfstate"
  })
}

module "spoke_network" {
  source = "../../modules/spoke-network"

  env           = local.env
  org_name      = var.org_name
  location      = var.location
  address_space = local.address_space
  dns_servers   = [local.hub_dns_resolver_ip]
  tags          = local.tags
}

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

module "test_vm" {
  source = "../../modules/test-vm"

  env                 = local.env
  resource_group_name = module.spoke_network.resource_group_name
  location            = var.location
  subnet_id           = module.spoke_network.app_subnet_id
  admin_password      = var.admin_password
  tags                = local.tags
}

module "keyvault" {
  source = "../../modules/keyvault"

  env                       = local.env
  resource_group_name       = module.spoke_network.resource_group_name
  location                  = var.location
  subnet_id                 = module.spoke_network.data_subnet_id
  vault_private_dns_zone_id = local.vault_dns_zone_id
  vm_identity_principal_id  = module.test_vm.identity_principal_id
  allowed_ip_rules          = var.allowed_ip_rules
  tags                      = local.tags
}

module "private_endpoints" {
  source = "../../modules/private-endpoints"

  env                      = local.env
  resource_group_name      = module.spoke_network.resource_group_name
  location                 = var.location
  subnet_id                = module.spoke_network.app_subnet_id
  blob_private_dns_zone_id = local.blob_dns_zone_id
  tags                     = local.tags
}
