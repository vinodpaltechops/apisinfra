# Centralised naming convention and shared values used across all layers.
# Every layer reads this file via a local path reference or copies needed values
# into its own locals block. In a real pipeline, these become a tfvars file.

locals {
  org_name     = "contoso"
  location     = "eastus2"
  location_short = "eus2"

  # Tag policy — every resource must carry these
  common_tags = {
    ManagedBy   = "Terraform"
    Organization = "Contoso"
    Repository  = "azure-landing-zone"
  }

  # Subscription IDs — in real enterprise these come from environment variables
  # or a secrets manager. Never hardcode real values here.
  subscriptions = {
    connectivity = "00000000-0000-0000-0000-000000000001"  # replace
    identity     = "00000000-0000-0000-0000-000000000002"  # replace
    dev          = "00000000-0000-0000-0000-000000000003"  # replace
    qa           = "00000000-0000-0000-0000-000000000004"  # replace
    prod         = "00000000-0000-0000-0000-000000000005"  # replace
  }

  # IP address plan — plan ALL ranges upfront, never overlap
  address_spaces = {
    hub       = "10.0.0.0/16"
    spoke_dev  = "10.1.0.0/16"
    spoke_qa   = "10.2.0.0/16"
    spoke_prod = "10.3.0.0/16"
  }
}
