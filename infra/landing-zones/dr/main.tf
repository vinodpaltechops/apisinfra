# LANDING ZONE: DR  (single state — landing-zones-dr)
#
# Warm-standby copy of the dev workload in a second region. Same shape as
# infra/landing-zones/dev, minus the things that do not need duplicating:
#
#   spoke-network (10.5.0.0/16) → global peering to hub → private AKS
#
# ── This whole LAYER is the DR toggle ─────────────────────────────────────────
# It is a self-contained directory with its own state file. To stand DR down,
# comment out the `dr` job in .github/workflows/terraform-deploy.yml (and run
# the destroy pipeline first if it is already deployed). Nothing in the dev
# landing zone, the hub, or the appgw layer references this layer, so removing
# it cannot break the running single-region stack.
#
# ── What is deliberately NOT here ─────────────────────────────────────────────
# Key Vault — the DR App Gateway reads the SAME certificate from the dev
#   spoke's vault. That vault keeps public_network_access_enabled = true with
#   default_action = Deny and the AzureServices bypass, which is exactly how the
#   primary gateway already reads it; the bypass is not region-scoped. A second
#   vault would mean a second copy of the certificate to rotate, i.e. a second
#   thing to forget.
#
# ACR — the DR cluster pulls from the SAME registry (data source below), so an
#   image built once is deployable in both regions with no promotion step. On
#   Basic that registry is a single-region dependency and therefore a genuine
#   DR gap: if the primary region loses ACR, the DR cluster can start already-
#   pulled images but cannot pull new ones. Closing it means Premium + a
#   geo-replication in dr_location — see acr_geo_replication_locations in
#   infra/landing-zones/dev/dr.tf.
#
# Jump/mgmt VMs — the mgmt VM in centralindia already reaches this cluster's API
#   server: both are private endpoints resolved through the hub resolver, and
#   this spoke is peered to the hub.
#
#   Note this puts management in a THIRD region. Managing the DR cluster during
#   a southindia outage therefore also depends on centralindia being up — one
#   of the known gaps in docs/disaster-recovery.md.

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
    container_name = "landing-zones-dr"
    key            = "landing-zones-dr.tfstate"
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

locals {
  env = "dr"

  address_space = "10.5.0.0/16"

  # Azure CNI Overlay pod CIDR. Intentionally DIFFERENT from the primary
  # cluster's 192.168.0.0/16 even though overlay CIDRs are cluster-local and
  # could legally be reused: keeping them distinct means a packet capture or an
  # NSG flow log is unambiguous about which cluster a pod IP belongs to, and it
  # leaves the door open to peering the two spokes later without renumbering.
  # 100.64.0.0/10 is RFC 6598 shared address space — not RFC1918, so it also
  # cannot collide with any on-prem range you later connect.
  aks_pod_cidr = "100.64.0.0/16"

  # STATIC private VIP for this region's internal ingress load balancer, mirroring
  # 10.1.2.250 in the dev spoke. The DR App Gateway's backend pool points at this
  # literal address, so it must survive the Service being recreated — a
  # dynamically assigned VIP would leave the gateway pointing at nothing after
  # any rebuild, with everything still reporting "Succeeded".
  #
  # Chosen high in snet-aks-user-dr (10.5.2.0/24) to stay clear of node IPs,
  # which Azure allocates from the bottom (.4, .5, ...).
  ingress_internal_ip = "10.5.2.250"

  # Region comes from the connectivity layer so it is defined ONCE (in
  # infra/platform/connectivity/dr.tf). The AKS private DNS zone name embeds
  # this region, so a mismatch between the two layers produces a cluster whose
  # API server FQDN resolves nowhere.
  location = data.terraform_remote_state.connectivity.outputs.dr_location

  tags = merge(var.common_tags, {
    Layer       = "LandingZone"
    Environment = local.env
    CostCenter  = "CloudPlatform"
    Role        = "DisasterRecovery"
  })

  hub_vnet_id             = data.terraform_remote_state.connectivity.outputs.hub_vnet_id
  hub_vnet_name           = data.terraform_remote_state.connectivity.outputs.hub_vnet_name
  hub_resource_group_name = data.terraform_remote_state.connectivity.outputs.hub_rg_name
  hub_dns_resolver_ip     = data.terraform_remote_state.connectivity.outputs.dns_inbound_ip
  hub_law_id              = data.terraform_remote_state.connectivity.outputs.law_id
  aks_dns_zone_id         = data.terraform_remote_state.connectivity.outputs.aks_dr_private_dns_zone_id

  # Reused from the dev landing zone — see the header for why each is shared
  # rather than duplicated.
  dev_resource_group_name = data.terraform_remote_state.dev.outputs.resource_group_name
  # mgmt_vm_principal_id  = data.terraform_remote_state.dev.outputs.mgmt_vm_identity_principal_id # dev's mgmt VM is disabled (feat/agc-centralindia)
  acr_name = data.terraform_remote_state.dev.outputs.acr_name
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

# The dev landing zone owns three things this layer reuses rather than
# duplicates: the mgmt VM's identity, the shared ACR, and the jump VNet. Read
# via remote state so nothing needs adding to dev's outputs.tf — this layer
# stays a pure addition that can be removed without editing dev.
#
# Ordering consequence: DR must be destroyed BEFORE dev, which is how the
# destroy pipeline sequences it.
data "terraform_remote_state" "dev" {
  backend = "azurerm"
  config = merge(local.tfstate_backend, {
    container_name = "landing-zones-dev"
    key            = "landing-zones-dev.tfstate"
  })
}

# The jump VNet's id/name are not dev outputs, so look the VNet up directly
# rather than adding outputs to dev for this layer's benefit.
data "azurerm_virtual_network" "jump" {
  name                = var.jump_vnet_name
  resource_group_name = local.dev_resource_group_name
}

# Fail at PLAN time with a readable message rather than at apply with an opaque
# private-cluster reconcile error, when someone deploys this layer while
# enable_dr_region is still false in the connectivity layer.
resource "terraform_data" "require_dr_dns_zone" {
  lifecycle {
    precondition {
      condition     = local.aks_dns_zone_id != null
      error_message = "connectivity has enable_dr_region = false, so privatelink.<dr_location>.azmk8s.io does not exist. Set it true in infra/platform/connectivity/dr.tf and apply the connectivity layer before this one."
    }
  }
}

# ── Spoke network: RG + VNet + subnets + NSG ──────────────────────────────────
module "spoke_network" {
  source = "../../modules/spoke-network"

  env           = local.env
  org_name      = var.org_name
  location      = local.location
  address_space = local.address_space
  dns_servers   = [local.hub_dns_resolver_ip]

  # The mgmt VM's jump VNet (10.4.0.0/24) manages this cluster too, so it needs
  # the same NSG exemption the dev spoke gives it. Without this the mgmt VM can
  # route to the DR API server's private endpoint but the spoke NSG drops it —
  # NSG IS enforced on private-endpoint subnets.
  mgmt_address_spaces = [var.jump_address_space]

  # Same overlay-pod requirement as dev: without it, cross-node pod traffic
  # (including every DNS query to CoreDNS) is dropped by deny-all-inbound while
  # every node still reports Ready.
  aks_pod_cidr = local.aks_pod_cidr
  tags         = local.tags
}

# ── Global peering to the hub ─────────────────────────────────────────────────
# Cross-region, so this is GLOBAL VNet peering — same as the existing jump VNet
# in centralindia. It carries exactly one thing that matters: DNS queries to the
# hub resolver, which is what resolves this cluster's private API FQDN.
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

# ── Global peering: jump VNet ↔ DR spoke ──────────────────────────────────────
# Peering is non-transitive, so jump↔hub does not reach this spoke. The mgmt VM
# needs a direct route to run kubectl against the DR API server's private
# endpoint — the same reason the dev spoke has its own jump peering.
#
# Both halves are declared here (not in the jump VNet's own layer) so that
# destroying this layer removes them; a peering owned by two states is the
# classic way to get a destroy that hangs.
resource "azurerm_virtual_network_peering" "jump_to_dr" {
  name                         = "peer-jump-to-dr-spoke"
  resource_group_name          = local.dev_resource_group_name
  virtual_network_name         = data.azurerm_virtual_network.jump.name
  remote_virtual_network_id    = module.spoke_network.vnet_id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

resource "azurerm_virtual_network_peering" "dr_to_jump" {
  name                         = "peer-dr-spoke-to-jump"
  resource_group_name          = module.spoke_network.resource_group_name
  virtual_network_name         = module.spoke_network.vnet_name
  remote_virtual_network_id    = data.azurerm_virtual_network.jump.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true

  # Serialising the two halves — the same fix already applied to the dev
  # peering (commit "Serialize the two halves of a VNet peering"). Azure rejects
  # concurrent writes to the two sides of a peering pair with a conflict on the
  # VNet resource.
  depends_on = [azurerm_virtual_network_peering.jump_to_dr]
}

# ── AKS cluster (private, BYO DNS zone in the hub) ────────────────────────────
module "aks" {
  source = "../../modules/aks"

  env                 = local.env
  location            = local.location
  resource_group_name = module.spoke_network.resource_group_name
  system_subnet_id    = module.spoke_network.subnet_ids["snet-aks-system-${local.env}"]
  user_subnet_id      = module.spoke_network.subnet_ids["snet-aks-user-${local.env}"]
  spoke_vnet_id       = module.spoke_network.vnet_id
  law_id              = local.hub_law_id

  # The DR-region zone from infra/platform/connectivity/dr.tf, NOT the
  # southindia one — the zone name embeds the cluster's region.
  aks_private_dns_zone_id = local.aks_dns_zone_id
  pod_cidr                = local.aks_pod_cidr
  tags                    = local.tags

  # Disabled with dev's mgmt VM (feat/agc-centralindia). While it is off this
  # private cluster is reached with `az aks command invoke`, which needs only
  # the operator grant below. Restore both lines when the VM comes back.
  # additional_admin_principals = {
  #   mgmt_vm = local.mgmt_vm_principal_id
  # }

  grant_operator_cluster_admin = true # lab: allow kubectl from your workstation

  depends_on = [terraform_data.require_dr_dns_zone]
}

# ── Image pull: the DR kubelet against the PRIMARY region's registry ──────────
# Data source rather than a remote-state read, so this layer stays removable:
# nothing has to be added to the dev landing zone's outputs, and commenting this
# layer out leaves no dangling reference behind.
data "azurerm_container_registry" "shared" {
  name                = local.acr_name
  resource_group_name = local.dev_resource_group_name
}

resource "azurerm_role_assignment" "dr_kubelet_acr_pull" {
  scope                            = data.azurerm_container_registry.shared.id
  role_definition_name             = "AcrPull"
  principal_id                     = module.aks.kubelet_identity
  skip_service_principal_aad_check = true # kubelet identity is an MSI, not an app registration
}
