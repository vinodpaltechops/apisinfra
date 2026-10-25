# LAYER: DNS — the public Azure DNS zone for the domain, replacing GoDaddy's
# nameservers as the place records are managed.
#
# Deployed AFTER trafficmanager: the app record is a CNAME to the profile's
# *.trafficmanager.net name, read from that layer's state rather than typed, so
# a rebuilt profile can never leave a stale target behind.
#
# ── Delegation is a separate, manual step ─────────────────────────────────────
# Applying this layer creates the zone but changes nothing for users: the
# internet still asks GoDaddy's nameservers until the registrar is told
# otherwise. See `terraform output delegation` for the order. Verify every
# record against the old zone BEFORE switching nameservers; after the switch,
# anything not copied here stops resolving (mail included).
#
# ── Removing it ───────────────────────────────────────────────────────────────
# Restore GoDaddy's nameservers at the registrar, then destroy this layer.
# Destroying first leaves the domain delegated to a zone that no longer exists:
# every lookup fails (SERVFAIL), not just app.

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
    container_name = "dns"
    key            = "dns.tfstate"
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

# State storage account + resource group. Same file `terraform init` reads via
# -backend-config, so the name lives in exactly one place.
locals {
  tfstate_backend = jsondecode(file("${path.module}/../../backend.json"))
}

locals {
  tags = merge(var.common_tags, {
    Layer      = "DNS"
    CostCenter = "CloudPlatform"
    Role       = "PublicDNS"
  })

  # "app.sometestdemo.in" -> "app", relative to the zone.
  app_record_name = trimsuffix(var.app_fqdn, ".${var.zone_name}")
}

data "terraform_remote_state" "trafficmanager" {
  backend = "azurerm"
  config = merge(local.tfstate_backend, {
    container_name = "trafficmanager"
    key            = "trafficmanager.tfstate"
  })
}

# DNS is global; this group only holds the zone's metadata.
resource "azurerm_resource_group" "dns" {
  name     = "rg-dns-${var.org_name}-001"
  location = var.location
  tags     = local.tags
}

resource "azurerm_dns_zone" "this" {
  name                = var.zone_name
  resource_group_name = azurerm_resource_group.dns.name
  tags                = local.tags
}

# The cutover record. Lives here, not in the trafficmanager layer, because the
# zone is what makes it real.
resource "azurerm_dns_cname_record" "app" {
  name                = local.app_record_name
  zone_name           = azurerm_dns_zone.this.name
  resource_group_name = azurerm_resource_group.dns.name
  ttl                 = var.app_ttl
  record              = data.terraform_remote_state.trafficmanager.outputs.fqdn
  tags                = local.tags
}

resource "azurerm_dns_cname_record" "extra" {
  for_each = var.cname_records

  name                = each.key
  zone_name           = azurerm_dns_zone.this.name
  resource_group_name = azurerm_resource_group.dns.name
  ttl                 = each.value.ttl
  record              = each.value.record
  tags                = local.tags
}

resource "azurerm_dns_a_record" "this" {
  for_each = var.a_records

  name                = each.key
  zone_name           = azurerm_dns_zone.this.name
  resource_group_name = azurerm_resource_group.dns.name
  ttl                 = each.value.ttl
  records             = each.value.records
  tags                = local.tags
}

resource "azurerm_dns_txt_record" "this" {
  for_each = var.txt_records

  name                = each.key
  zone_name           = azurerm_dns_zone.this.name
  resource_group_name = azurerm_resource_group.dns.name
  ttl                 = each.value.ttl
  tags                = local.tags

  dynamic "record" {
    for_each = each.value.values
    content {
      value = record.value
    }
  }
}

resource "azurerm_dns_mx_record" "this" {
  for_each = var.mx_records

  name                = each.key
  zone_name           = azurerm_dns_zone.this.name
  resource_group_name = azurerm_resource_group.dns.name
  ttl                 = each.value.ttl
  tags                = local.tags

  dynamic "record" {
    for_each = each.value.records
    content {
      preference = record.value.preference
      exchange   = record.value.exchange
    }
  }
}
