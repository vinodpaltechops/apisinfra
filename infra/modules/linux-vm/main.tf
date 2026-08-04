# MODULE: linux-vm
# A private Linux jump/utility VM (no public IP) with a system-assigned managed
# identity and Azure AD SSH login. Reach it with `az ssh vm` over the hub
# Bastion/peering — no SSH keys to distribute, no public IP. cloud-init installs
# az CLI, kubectl and helm on first boot.
#
# NOTE: the caller's provider must set features { virtual_machine { ... } }
# (the dev env root already does).

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
  }
}

locals {
  vm_name = "vm-jump-${var.env}-001"
}

data "azurerm_client_config" "current" {}

# ── NIC — private IP only, no public IP ───────────────────────────────────────
resource "azurerm_network_interface" "jump" {
  name                = "nic-${local.vm_name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
    # No public IP — connect via `az ssh vm` (AAD login) over peering.
  }
}

# ── Linux VM ───────────────────────────────────────────────────────────────────
resource "azurerm_linux_virtual_machine" "jump" {
  name                  = local.vm_name
  resource_group_name   = var.resource_group_name
  location              = var.location
  size                  = var.vm_size
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.jump.id]

  # SSH key auth — no password auth. pathexpand handles a leading ~.
  admin_ssh_key {
    username   = var.admin_username
    public_key = file(pathexpand(var.ssh_public_key_path))
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  # Cloud-init: installs az CLI, kubectl, helm on first boot.
  custom_data = base64encode(file("${path.module}/cloud-init.yaml"))

  # System-assigned managed identity — for az login, kubectl, Key Vault access.
  identity {
    type = "SystemAssigned"
  }

  tags = var.tags
}

# ── VM Extension: Azure AD SSH Login ──────────────────────────────────────────
# Lets you SSH with `az ssh vm` using your Azure AD credentials — no SSH key
# management needed on the client side.
resource "azurerm_virtual_machine_extension" "aad_ssh" {
  name                 = "AADSSHLoginForLinux"
  virtual_machine_id   = azurerm_linux_virtual_machine.jump.id
  publisher            = "Microsoft.Azure.ActiveDirectory"
  type                 = "AADSSHLoginForLinux"
  type_handler_version = "1.0"
  tags                 = var.tags
}

# ── RBAC: allow the caller's account to SSH into the VM ───────────────────────
resource "azurerm_role_assignment" "vm_admin_login" {
  scope                = azurerm_linux_virtual_machine.jump.id
  role_definition_name = "Virtual Machine Administrator Login"
  principal_id         = data.azurerm_client_config.current.object_id
}
