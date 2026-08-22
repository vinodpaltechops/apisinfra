# Committed + CI-loaded (see .gitignore `!*.auto.tfvars`). NO SECRETS here.
# mg_ids are read from the management-groups layer's remote state.
# southindia        — hub, dev spoke, dev AKS
# centralindia      — jump VNet + mgmt VM (separate regional vCPU quota)
# indiasouthcentral — DR spoke + DR AKS (Hyderabad)
#
# This feeds a DENY-effect assignment at the org root, so a region missing from
# this list fails the apply rather than warning. It must be applied BEFORE any
# layer deploying into that region — the pipeline already orders policies (2)
# ahead of the DR landing zone (6).
#
# "global" needs no entry: the built-in Allowed-locations definition exempts
# location == "global", which is what Front Door registers as.
allowed_locations = ["southindia", "centralindia", "indiasouthcentral"]
