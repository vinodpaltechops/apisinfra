# Committed + CI-loaded (see .gitignore `!*.auto.tfvars`). NO SECRETS here.
# admin_password is NOT here — it comes from the GitHub secret
# TF_VAR_ADMIN_PASSWORD (locally it stays in the gitignored terraform.tfvars).
# The /24 holding your current address, not a /32: this connection is dynamic,
# and a /32 locks you out on the next DHCP re-lease. The VM takes SSH keys only
# (disable_password_authentication = true), so the allow-list is defence in
# depth rather than the only control, and a /24 is a reasonable trade.
#
# Note it is not a guarantee. The ISP's allocation is 106.51.192.0/19
# (106.51.192.0-106.51.223.255), so a re-lease CAN land outside this /24. When
# SSH starts timing out rather than refusing — the NSG drops packets, so it
# hangs — run `curl -s https://api.ipify.org`, update BOTH lines and re-apply.
# Widening to the full /19 would stop that, at the cost of admitting ~8k of the
# ISP's other customers to the one public door into this stack.
allowed_ip_rules       = ["106.51.211.0/24"] # your ISP range (KV secret seeding)
mgmt_ssh_source_prefix = "106.51.211.0/24"   # SSH into the public mgmt VM

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
