# Committed + CI-loaded (see .gitignore `!*.auto.tfvars`). NO SECRETS here.
# admin_password is NOT here — it comes from the GitHub secret
# TF_VAR_ADMIN_PASSWORD (locally it stays in the gitignored terraform.tfvars).
allowed_ip_rules       = ["163.223.165.0/24"] # your ISP range (KV secret seeding)
mgmt_ssh_source_prefix = "163.223.165.0/24"   # SSH into the public mgmt VM

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
