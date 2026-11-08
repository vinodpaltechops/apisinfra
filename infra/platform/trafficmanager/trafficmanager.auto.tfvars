# Committed + CI-loaded (see .gitignore `!*.auto.tfvars`). NO SECRETS here.

org_name = "vinorg"
location = "southindia" # metadata resource group only — Traffic Manager is global

# The application's public name. Used only to print DNS and verification
# commands; the dns layer owns the record.
app_fqdn = "app.sometestdemo.in"

# The Host header on every health probe. It must equal health.hostname in the
# agc-gateway chart (k8s/gitops/platform/agc-gateway/values.yaml): that hostname
# routes to the platform health responder, so this endpoint reads Online whenever
# the gateway and cluster are reachable, with no application deployed. A mismatch
# gets a 404 from the gateway and degrades the endpoint while everything is up.
# No DNS record is needed — Traffic Manager names the host itself.
health_hostname = "health.sometestdemo.in"

# Where the primary endpoint lives. Informational under Priority routing.
primary_location = "centralindia"
dr_location      = "indiasouthcentral"

# ── Two live entrances for app_fqdn ───────────────────────────────────────────
# appgw  App Gateway in front of the internal ingress-nginx.  Probed on app_fqdn,
#        so it is Online only while an nginx app answers there.
# agc    The AGC Gateway.  Probed on health_hostname, so it is Online whenever the
#        gateway is up, with or without an app.
#
# The App Gateway ranks FIRST on purpose. AGC is always Online, so ranked first it
# would take every query even when the app is deployed behind nginx and the App
# Gateway would never be asked. With App Gateway first, whichever entrance really
# serves the app wins by itself: nginx app -> App Gateway; AGC app -> App Gateway
# reads Degraded and AGC answers. Content Hub's two variants cannot run together,
# so exactly one is true.
#
# The App Gateway listener is bound to ONE hostname, so it can only front app_fqdn.
# Set false together with the appgw job in terraform-deploy.yml.
enable_appgw_endpoint = true
appgw_priority        = 1
agc_priority          = 2
dr_priority           = 3

# Set false to run with the primary endpoint only — either before the DR region
# exists, or to park DR without destroying the profile. Neither is user-visible;
# the endpoint keeps serving from the primary.
# false while the DR region is disabled in the pipeline — with true this layer
# reads the appgw-dr state, which nothing has written, and fails at plan.
#
# The profile then holds ONE endpoint, which fails over nowhere. That is the
# point of keeping it: the *.trafficmanager.net hostname survives, so
# re-enabling DR needs no registrar change. Flip back with the pipeline's
# appgw-dr job.
enable_dr_endpoint = false

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
# The AGC Gateway has only a port-80 listener (see the note in its gateway.yaml:
# AGC cannot read Key Vault, so TLS needs a certificate Secret). Probing HTTPS
# against it fails every probe and reports the endpoint Degraded — which looks
# exactly like a broken failover design rather than a protocol mismatch.
#
# These two settings and the Gateway's listeners must always move together.
# After a 443 listener exists:
#   health_probe_protocol = "HTTPS"
#   health_probe_port     = 443
health_probe_path     = "/healthz"
health_probe_protocol = "HTTP"
health_probe_port     = 80
