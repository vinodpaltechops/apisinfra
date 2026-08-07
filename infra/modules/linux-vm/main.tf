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
  vm_name = "vm-${var.role}-${var.env}-001"
}

data "azurerm_client_config" "current" {}

# ── Optional public IP (enable_public_ip = true) ──────────────────────────────
# Only for a public entry/bastion-replacement VM. A private jump keeps this off
# and is reached via peering (az ssh vm / from the mgmt VM).
resource "azurerm_public_ip" "vm" {
  count               = var.enable_public_ip ? 1 : 0
  name                = "pip-${local.vm_name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

# ── NIC ───────────────────────────────────────────────────────────────────────
resource "azurerm_network_interface" "jump" {
  name                = "nic-${local.vm_name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
    # Public IP only when enable_public_ip = true; null keeps a private jump.
    public_ip_address_id = var.enable_public_ip ? azurerm_public_ip.vm[0].id : null
  }
}

# ── NIC-level NSG for the public VM — SSH from your IP only ────────────────────
# Attached to the NIC (not the subnet) so it doesn't affect the private jump
# sharing the subnet. Only created when the VM is public.
resource "azurerm_network_security_group" "vm" {
  count               = var.enable_public_ip ? 1 : 0
  name                = "nsg-${local.vm_name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  security_rule {
    name                       = "allow-ssh-from-source"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = var.ssh_source_prefix
    destination_address_prefix = "*"
    source_port_range          = "*"
    destination_port_range     = "22"
  }

  security_rule {
    name                       = "allow-azure-lb"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
  }

  security_rule {
    name                       = "deny-internet-inbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
  }
}

resource "azurerm_network_interface_security_group_association" "vm" {
  count                     = var.enable_public_ip ? 1 : 0
  network_interface_id      = azurerm_network_interface.jump.id
  network_security_group_id = azurerm_network_security_group.vm[0].id
}

# ── Linux VM ───────────────────────────────────────────────────────────────────
resource "azurerm_linux_virtual_machine" "jump" {
  name                  = local.vm_name
  resource_group_name   = var.resource_group_name
  location              = var.location
  size                  = var.vm_size
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.jump.id]

  # SSH key auth — no password auth. Prefer the key CONTENT passed in
  # (var.ssh_public_key — set in CI via TF_VAR_ssh_public_key); fall back to
  # reading a local file (var.ssh_public_key_path) for laptop runs. try() keeps
  # the missing-file case from erroring on the CI runner. pathexpand handles ~.
  admin_ssh_key {
    username   = var.admin_username
    public_key = coalesce(var.ssh_public_key, try(file(pathexpand(var.ssh_public_key_path)), null))
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
