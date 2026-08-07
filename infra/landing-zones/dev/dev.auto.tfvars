# Committed + CI-loaded (see .gitignore `!*.auto.tfvars`). NO SECRETS here.
# admin_password is NOT here — it comes from the GitHub secret
# TF_VAR_ADMIN_PASSWORD (locally it stays in the gitignored terraform.tfvars).
allowed_ip_rules       = ["163.223.165.0/24"] # your ISP range (KV secret seeding)
mgmt_ssh_source_prefix = "163.223.165.0/24"   # SSH into the public mgmt VM
