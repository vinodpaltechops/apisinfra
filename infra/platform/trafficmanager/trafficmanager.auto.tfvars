# Committed + CI-loaded (see .gitignore `!*.auto.tfvars`). NO SECRETS here.

org_name = "vinorg"
location = "southindia" # metadata resource group only — Traffic Manager is global

# MUST match app_fqdn in BOTH infra/platform/appgw and infra/platform/appgw-dr.
# It is also the Host header on every health probe: both gateways listen
# host-based, so a mismatch here degrades every endpoint while the app is up.
app_fqdn = "app.sometestdemo.in"

primary_location = "southindia"
dr_location      = "indiasouthcentral"

# Set false to run with the primary endpoint only — either before the DR region
# exists, or to park DR without destroying the profile. Neither is user-visible;
# the endpoint keeps serving from the primary.
enable_dr_endpoint = true

# ── Failover timing ───────────────────────────────────────────────────────────
# Detection = interval x (tolerated_failures + 1) = 30 x 4 ≈ 2 min.
# Then clients must re-resolve, which the TTL below bounds from BELOW only:
# browsers and resolvers cache beyond it, so treat the real RTO as 2-4 minutes
# rather than 2.5.
#
# Do not tighten these casually. Traffic Manager moves traffic by changing an
# answer clients have already cached, so a flap leaves some users on the old
# region and some on the new, for as long as their caches hold.
ttl                           = 30
health_probe_interval_seconds = 30
tolerated_number_of_failures  = 3

# ── HTTP for now — MUST move to HTTPS with the gateways ───────────────────────
# Both App Gateways are currently enable_https = false (see the stale-vault note
# in appgw.auto.tfvars), so neither has a :443 listener. Probing HTTPS against
# them fails every probe and reports BOTH endpoints Degraded — which looks
# exactly like a broken failover design rather than a protocol mismatch.
#
# These two settings and the gateways' enable_https must always move together.
# After the certificate is imported and both gateways are flipped to true:
#   health_probe_protocol = "HTTPS"
#   health_probe_port     = 443
health_probe_path     = "/healthz"
health_probe_protocol = "HTTP"
health_probe_port     = 80
