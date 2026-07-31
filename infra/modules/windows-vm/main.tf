# MODULE: test-vm
# A private Windows VM (no public IP) with a system-assigned managed identity.
# Reachable only via the hub Bastion over peering. The managed identity's
# principal_id is exported so the Key Vault module can grant it Secrets User.
#
# NOTE: this module needs the provider's virtual_machine feature block set by
# the caller: features { virtual_machine { delete_os_disk_on_deletion = true } }

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
  }
}

locals {
  vm_name = "vm-test-${var.env}-001"
}

resource "azurerm_network_interface" "vm" {
  name                = "nic-${local.vm_name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
    # No public_ip_address_id — intentionally private only.
  }
}

resource "azurerm_windows_virtual_machine" "this" {
  name                  = local.vm_name
  resource_group_name   = var.resource_group_name
  location              = var.location
  size                  = var.vm_size
  admin_username        = var.admin_username
  admin_password        = var.admin_password
  network_interface_ids = [azurerm_network_interface.vm.id]

  identity {
    type = "SystemAssigned"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-Datacenter"
    version   = "latest"
  }

  tags = var.tags
}
