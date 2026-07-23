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
    storage_account_name = "stotfstatevinorgmjslia"
    container_name       = "test-vm"
    key                  = "test-vm.tfstate"
  }
}

provider "azurerm" {
  features {
    virtual_machine {
      delete_os_disk_on_deletion = true
      graceful_shutdown = false
    }
  }
}

locals {
    env   = "dev"
    vm_name = "vm-test-dev-001"
    tags = {
    Environment = "Dev"
    ManagedBy   = "Terraform"
    Purpose     = "ConnectivityTest"
    }

    # Pulled from the dev landing-zone's remote state — tfvars can't hold
    # expressions/references, only literal values, so these can't be set
    # via terraform.tfvars.
    resource_group_name = data.terraform_remote_state.dev.outputs.resource_group_name
    subnet_id            = data.terraform_remote_state.dev.outputs.spoke_subnet_ids["snet-app-${local.env}"]
}

# ── NIC — private IP only, no public IP ───────────────────────────────────────
# This is the point of the exercise — VM is reachable ONLY via Bastion
# through the hub peering, not directly from internet
resource "azurerm_network_interface" "vm" {
  name                = "nic-${local.vm_name}"
  resource_group_name = local.resource_group_name
  location            = var.location
  tags                = local.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = local.subnet_id
    private_ip_address_allocation = "Dynamic"
    # No public_ip_address_id — intentionally private only
  }
}

# ── Windows VM — B1s is free tier eligible ────────────────────────────────────
resource "azurerm_windows_virtual_machine" "test" {
  name                = local.vm_name
  resource_group_name = local.resource_group_name
  location            = var.location
  size                = "Standard_B2ats_v2"   # free tier eligible, cheapest Windows VM
  admin_username      = "azureadmin"
  admin_password      = var.admin_password

  # No public IP — this enforces our security model
  network_interface_ids = [azurerm_network_interface.vm.id]

  # ADD THIS BLOCK — enables system-assigned managed identity
  identity {
    type = "SystemAssigned"
    # Azure creates an Entra ID service principal automatically
    # named exactly the same as the VM
    # You never see or manage the credential
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"  # cheapest disk tier
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-Datacenter"
    version   = "latest"
  }

  # Disable password auth is Windows-only concern
  # For Linux VMs you would use admin_ssh_key block instead

  tags = local.tags
}

data "terraform_remote_state" "dev" {
  backend = "azurerm"
  config = {
    resource_group_name  = "rg-tfstate-vinorg-001"
    storage_account_name = "stotfstatevinorgmjslia"
    container_name       = "landing-zones-dev"
    key                  = "landing-zones-dev.tfstate"
  }
  
}