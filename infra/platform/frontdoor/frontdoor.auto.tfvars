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
health_probe_path = "/healthz"

# ── Http for the rebuild — MUST move to Https with the gateways ───────────────
# Both App Gateways are currently enable_https = false (see the stale-vault note
# in appgw.auto.tfvars), so they have NO :443 listener at all. Probing or
# forwarding over Https against them fails every request and reports BOTH
# origins unhealthy — which looks exactly like a broken failover design rather
# than a protocol mismatch, and is a genuinely confusing hour to spend.
#
# These two settings and the gateways' enable_https must always move together.
# After the certificate is imported and both gateways are flipped to true:
#   health_probe_protocol = "Https"
#   forwarding_protocol   = "HttpsOnly"
#
# Leaving them as Http afterwards is worse than a mismatch: it silently sends
# real traffic to the origin unencrypted while the client-to-edge leg still
# shows a padlock.
health_probe_protocol         = "Http"
health_probe_interval_seconds = 30

forwarding_protocol = "HttpOnly"
