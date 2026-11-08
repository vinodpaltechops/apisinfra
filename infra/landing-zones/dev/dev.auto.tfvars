# Committed + CI-loaded (see .gitignore `!*.auto.tfvars`). NO SECRETS here.
# admin_password is NOT here — it comes from the GitHub secret
# TF_VAR_ADMIN_PASSWORD (locally it stays in the gitignored terraform.tfvars).
# SSH is open to the internet on purpose: the laptop's ISP address changes, and
# chasing it meant an edit and an apply on every re-lease. The VM takes SSH keys
# only (disable_password_authentication = true), so what is exposed is a key
# login, not a password prompt — expect brute-force noise in the auth log, none
# of which can succeed without the private key.
#
# To lock it down again, set a CIDR here (e.g. your ISP's /24) and re-apply.
allowed_ip_rules       = ["163.223.164.0/24"] # your ISP range (KV secret seeding)
mgmt_ssh_source_prefix = "Internet"           # NSG service tag: any public address

# Lets the mgmt VM's identity run `az keyvault certificate import` for the App
# Gateway TLS cert (the vault is private, so that only works from inside the
# VNet). Not a secret, so it must live HERE and not in terraform.tfvars —
# terraform.tfvars is gitignored, so CI never sees it and would silently fall
# back to the default of false, and the import would 403.
#
# Set back to false once the certificate is installed; it is write access to
# private keys. The gateway keeps working — it reads the cert with its own
# identity, which only needs Secrets User.
grant_vm_certificate_officer = true

# ── DR: registry geo-replication ──────────────────────────────────────────────
# OFF by default — the registry stays Basic and single-region, exactly as it is
# today. Uncomment BOTH lines together to give the DR cluster a local replica;
# the module validation rejects the list without the Premium SKU.
#
# The trade-off is cost, not risk: Premium is ~10x Basic. Leaving this off means
# the DR cluster pulls across regions from southindia, which works but puts the
# registry on the recovery path — see the note in infra/landing-zones/dr/main.tf.
#
# acr_sku                       = "Premium"
# acr_geo_replication_locations = ["indiasouthcentral"] # must match connectivity's dr_location
