# Committed + CI-loaded (see .gitignore `!*.auto.tfvars`). NO SECRETS here.
#
# Your ISP range, so the TLS certificate can be imported from a laptop
# (docs/public-endpoint.md, step 6). Keep in step with aks_authorized_ip_ranges
# in the dev landing zone if the range changes.
allowed_ip_rules = ["163.223.164.0/24"]
