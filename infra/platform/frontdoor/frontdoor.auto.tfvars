# Committed + CI-loaded (see .gitignore `!*.auto.tfvars`). NO SECRETS here.

org_name = "vinorg"
location = "southindia" # metadata resource group only — Front Door is global

# MUST match app_fqdn in BOTH infra/platform/appgw and infra/platform/appgw-dr.
app_fqdn = "app.sometestdemo.in"

# Standard is enough: each App Gateway already runs the OWASP 3.2 managed rule
# set, so Premium's managed WAF would be a second copy of the same inspection.
# Premium's real draw is Private Link to origins, which would let both gateways
# drop their public IPs entirely.
sku_name = "Standard_AzureFrontDoor"

# Set false to run Front Door with the primary origin only — either before the
# DR region exists, or to park DR without destroying anything. Neither is
# user-visible; the endpoint keeps serving from the primary.
enable_dr_origin = true

# Detection window = interval x sample_size (30s x 4) ≈ 2 minutes before Front
# Door declares an origin down and shifts to the standby. Lowering it makes
# transient blips flap traffic between regions, which is worse than a brief 502.
health_probe_path             = "/healthz"
health_probe_protocol         = "Https"
health_probe_interval_seconds = 30

forwarding_protocol = "HttpsOnly"
