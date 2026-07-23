terraform {
  required_version = ">=1.7.0"
  required_providers {
    azurerm = {
        source  = "hashicorp/azurerm"
        version = "~> 3.110"
    }
  } 
  backend "azurerm" {
    resource_group_name  = "rg-tfstate-vinorg-001"
    storage_account_name = "stotfstatevinorgmjslia"
    container_name       = "keyvault"
    key                  = "keyvault.tfstate"
  }
}

provider "azurerm" {
  features {
    key_vault {
      # Safety: don't destroy KV if it has secrets
      # Forces explicit purge — prevents accidental data loss
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
  }
}

data "azurerm_client_config" "current" {}
data "terraform_remote_state" "dev" {
  backend = "azurerm"
  config = {
    resource_group_name  = "rg-tfstate-vinorg-001"
    storage_account_name = "stotfstatevinorgmjslia"
    container_name       = "landing-zones-dev"
    key                  = "landing-zones-dev.tfstate"
  }
}
  
locals {
  tags = {
    Environment = "Dev"
    ManagedBy   = "Terraform"
    Layer       = "KeyVault"
  }
}

# Random suffix — KV names must be globally unique and 3-24 chars
resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

# ── Key Vault ──────────────────────────────────────────────────────────────────
resource "azurerm_key_vault" "dev" {
  name                = "kv-dev-lab-${random_string.suffix.result}"
  resource_group_name = data.terraform_remote_state.dev.outputs.resource_group_name
  location            = var.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  # RBAC mode — modern approach
  # Alternative is access policies (legacy) — always use RBAC in new setups
  # RBAC lets you use standard Azure role assignments instead of KV-specific policies
  enable_rbac_authorization = true

  # Soft delete: deleted secrets recoverable for 7 days
  # Mandatory in Azure — cannot be disabled
  soft_delete_retention_days = 7

  # Purge protection: prevents permanent deletion during retention period
  # Required for HSM-backed keys and compliance scenarios
  purge_protection_enabled = false  # false for lab — easier cleanup

  # Public endpoint stays ON but firewalled to specific IPs (var.allowed_ip_rules)
  # + the private endpoint. This lets Terraform seed secrets from your
  # workstation. Setting this to false would turn the public endpoint off
  # entirely and ip_rules would be ignored (private endpoint only).
  public_network_access_enabled = true

  network_acls {
    default_action = "Deny"                # deny everything not explicitly allowed
    bypass         = "AzureServices"        # allow Azure trusted services
    ip_rules       = var.allowed_ip_rules   # allow your workstation IP(s) — set in terraform.tfvars
  }

  tags = local.tags
}

# ── Secret — what the VM will read ────────────────────────────────────────────
resource "azurerm_key_vault_secret" "db_password" {
  name         = "db-password"
  value        = "SuperSecret123!"
  key_vault_id = azurerm_key_vault.dev.id

  # Secret is only accessible via private endpoint
  # VM managed identity must have Key Vault Secrets User role to read it

  tags = local.tags

  depends_on = [
    # RBAC assignments must exist before writing secrets
    # Otherwise Terraform itself cannot write the secret
    azurerm_role_assignment.terraform_sp_kv_admin
  ]
}

resource "azurerm_key_vault_secret" "app_config" {
  name         = "app-config-value"
  value        = "my-application-configuration-string"
  key_vault_id = azurerm_key_vault.dev.id

  tags = local.tags

  depends_on = [azurerm_role_assignment.terraform_sp_kv_admin]
}

# ── RBAC Assignments ───────────────────────────────────────────────────────────

# 1. Terraform SP needs Key Vault Administrator to CREATE secrets
#    Without this, Terraform cannot write the secrets above
resource "azurerm_role_assignment" "terraform_sp_kv_admin" {
  scope                = azurerm_key_vault.dev.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
  # data.azurerm_client_config.current.object_id = the SP running Terraform
}

# 2. VM Managed Identity gets Key Vault Secrets User
#    This allows READ of secret values only
#    Cannot create, update, or delete secrets
#    Least privilege — VM only needs to READ
resource "azurerm_role_assignment" "vm_identity_kv_secrets_user" {
  scope                = azurerm_key_vault.dev.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = data.terraform_remote_state.test-vm.outputs.vm_identity_principal_id
  # data.terraform_remote_state.test-vm.outputs.vm_identity_principal_id = the VM's managed identity object ID
  # This is the VM's managed identity object ID
}

# ── Private Endpoint for Key Vault ────────────────────────────────────────────
resource "azurerm_private_endpoint" "keyvault" {
  name                = "pe-keyvault-dev"
  resource_group_name = data.terraform_remote_state.dev.outputs.resource_group_name
  location            = var.location
  subnet_id           = data.terraform_remote_state.dev.outputs.spoke_subnet_ids["snet-data-dev"]

  private_service_connection {
    name                           = "psc-keyvault-dev"
    private_connection_resource_id = azurerm_key_vault.dev.id
    is_manual_connection           = false
    subresource_names              = ["vault"]
    # Key Vault has only one subresource: "vault"
    # Compare with Storage which has: blob, file, queue, table
  }

  private_dns_zone_group {
    name                 = "pdz-group-vault"
    private_dns_zone_ids = [azurerm_private_dns_zone.vault.id]
  }

  tags = local.tags
}

# ── Private DNS Zone for Key Vault ────────────────────────────────────────────
# Different zone name from storage — each service has its own privatelink zone
resource "azurerm_private_dns_zone" "vault" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = data.terraform_remote_state.dev.outputs.resource_group_name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "vault_hub" {
  name                  = "link-vault-zone-to-hub"
  resource_group_name   = data.terraform_remote_state.dev.outputs.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.vault.name
  virtual_network_id    = data.terraform_remote_state.connectivity.outputs.hub_vnet_id
  registration_enabled  = false
  tags                  = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "vault_dev_spoke" {
  name                  = "link-vault-zone-to-dev-spoke"
  resource_group_name   = data.terraform_remote_state.dev.outputs.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.vault.name
  virtual_network_id    = data.terraform_remote_state.dev.outputs.spoke_vnet_id
  registration_enabled  = false
  tags                  = local.tags
}

data "terraform_remote_state" "connectivity" {
  backend = "azurerm"
  config = {
    resource_group_name  = "rg-tfstate-vinorg-001"
    storage_account_name = "stotfstatevinorgmjslia"
    container_name       = "connectivity"
    key                  = "connectivity.tfstate"
  }
  
}

data "terraform_remote_state" "test-vm" {
  backend = "azurerm"
  config = {
    resource_group_name  = "rg-tfstate-vinorg-001"
    storage_account_name = "stotfstatevinorgmjslia"
    container_name       = "test-vm"
    key                  = "test-vm.tfstate"
  }
  
}