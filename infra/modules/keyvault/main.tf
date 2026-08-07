# MODULE: keyvault
# RBAC-enabled Key Vault reached ONLY via a private endpoint. The VM's managed
# identity is granted Secrets User.
#
# HARDENED: public_network_access_enabled = false — no public data-plane access.
# Terraform (run from your laptop) manages the vault itself (control plane) but
# CANNOT seed secrets (data plane); seed those from inside the network (mgmt/jump
# VM) via `az keyvault secret set` — see the commented secret resources below.
#
# NOTE: this module needs the provider's key_vault feature block set by the
# caller: features { key_vault { purge_soft_delete_on_destroy = false ... } }
#
# The privatelink.vaultcore DNS zone is centralized in the hub (connectivity)
# layer and linked to the hub once; this module only registers the KV private
# endpoint into it via var.vault_private_dns_zone_id. Safe for all environments.

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

resource "azurerm_key_vault" "this" {
  name                          = "kv-${var.env}-lab-${random_string.suffix.result}"
  resource_group_name           = var.resource_group_name
  location                      = var.location
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "standard"
  enable_rbac_authorization     = true
  soft_delete_retention_days    = 7
  purge_protection_enabled      = false # false for lab — easier cleanup
  public_network_access_enabled = false

  # NOTE: while public_network_access_enabled = false, these ip_rules are INERT
  # (the public endpoint is fully off — only the private endpoint + trusted
  # AzureServices reach the data plane). They take effect only if you flip public
  # access back on. bypass = AzureServices lets the AKS CSI provider etc. through.
  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
    ip_rules       = var.allowed_ip_rules
  }

  tags = var.tags
}

# Terraform's own identity needs Administrator to write secrets
resource "azurerm_role_assignment" "terraform_sp_kv_admin" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

# The VM's managed identity gets read-only access to secret values
resource "azurerm_role_assignment" "vm_identity_kv_secrets_user" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = var.vm_identity_principal_id
}

# ── Secrets — NOT managed by Terraform (hardened: public access OFF) ───────────
# With public_network_access_enabled = false, secret writes are a DATA-plane op
# that only works from INSIDE the network (via the private endpoint). Terraform
# runs from your laptop (public), so it can't seed secrets — that's by design.
# Seed them from the mgmt/jump VM, which reaches the KV private endpoint. Log in
# as YOURSELF (you hold Key Vault Administrator) — NOT `az login --identity`, as
# the VM's managed identity is only Secrets User (read-only), so a write 403s:
#   az login --use-device-code
#   az keyvault secret set --vault-name <kv-name> --name db-password       --value '<secret>'
#   az keyvault secret set --vault-name <kv-name> --name app-config-value  --value '<secret>'
# Re-enable these (and set public_network_access_enabled = true + ip_rules) if
# you'd rather have Terraform manage them from your workstation again.
# resource "azurerm_key_vault_secret" "db_password" {
#   name         = "db-password"
#   value        = var.db_password_value
#   key_vault_id = azurerm_key_vault.this.id
#   tags         = var.tags
#
#   depends_on = [azurerm_role_assignment.terraform_sp_kv_admin]
# }
#
# resource "azurerm_key_vault_secret" "app_config" {
#   name         = "app-config-value"
#   value        = var.app_config_value
#   key_vault_id = azurerm_key_vault.this.id
#   tags         = var.tags
#
#   depends_on = [azurerm_role_assignment.terraform_sp_kv_admin]
# }

# ── Private endpoint + DNS ────────────────────────────────────────────────────
resource "azurerm_private_endpoint" "keyvault" {
  name                = "pe-keyvault-${var.env}"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.subnet_id

  private_service_connection {
    name                           = "psc-keyvault-${var.env}"
    private_connection_resource_id = azurerm_key_vault.this.id
    is_manual_connection           = false
    subresource_names              = ["vault"]
  }

  private_dns_zone_group {
    name                 = "pdz-group-vault"
    private_dns_zone_ids = [var.vault_private_dns_zone_id]
  }

  tags = var.tags
}
