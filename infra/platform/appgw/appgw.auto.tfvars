# Committed + CI-loaded (see .gitignore `!*.auto.tfvars`). NO SECRETS here.
#
# CHANGE app_fqdn to your real GoDaddy domain before applying — it is baked
# into the listener, the Host header sent to the ingress, and (later) the TLS
# certificate subject.
app_fqdn = "app.sometestdemo.in"

# Must match service.beta.kubernetes.io/azure-load-balancer-ipv4 in
# k8s/platform/ingress-nginx-values.yaml.
ingress_internal_ip = "10.1.2.250"

waf_mode = "Prevention"

# ── TLS ───────────────────────────────────────────────────────────────────────
# false = HTTP only. Flip to true once the certificate is in Key Vault and the
# two settings below are filled in. Toggling does not change the public IP, so
# the GoDaddy A record keeps working either way.
#
# HTTP-only for now: the dev vault was recreated empty by the move to
# centralindia, and applying with true before app-tls is imported fails with
# ApplicationGatewayKeyVaultSecretNotFound. To turn it back on: import the
# certificate (docs/public-endpoint.md, step 6), set both values below to true,
# and re-apply. Matches appgw-dr.auto.tfvars.
enable_https = false

# Only read when enable_https = true.
#   true  — :80 permanently redirects to :443 (right answer for a public site)
#   false — :80 keeps serving the app too, so http:// and https:// both work
# Must be false while HTTPS is off, or :80 would redirect to a port with no
# listener.
http_redirect_to_https = false

# ── Certificate: read from the dev landing zone's vault ───────────────────────
# Nothing to type. With enable_https = true the vault's resource ID and URI come
# from the dev landing zone's state (outputs key_vault_id / key_vault_uri), and
# the secret URL is "<vault uri>secrets/<ssl_certificate_secret_name>" — so a
# rebuild's new random vault suffix is picked up automatically.
#
# What stays manual is putting the certificate INTO the vault, under the name in
# ssl_certificate_secret_name (default "app-tls"): it must be done from inside
# the VNet (the vault has no public endpoint) — see docs/public-endpoint.md.
# Applying with enable_https = true BEFORE that fails with
# ApplicationGatewayKeyVaultSecretAccessDenied, which reads like an RBAC problem
# but just means the secret is not there yet.
#
# Dev must have been re-applied once so it exports key_vault_id.
# ssl_certificate_secret_name = "app-tls"
#
# Both gateways share ONE certificate: appgw-dr reads the same vault.
# The module creates its own managed identity and grants it Key Vault Secrets
# User — do not create that role assignment by hand, or the apply fails with
# RoleAssignmentExists.
#
# To pin a specific vault or secret instead, set ssl_certificate_key_vault_secret_id
# and key_vault_id here; explicit values win.

# ["Internet"] = a genuinely public site. While testing you can narrow this to
# your own ISP range, e.g. ["163.223.165.0/24"], and widen it once it works.
allowed_source_prefixes = ["Internet"]

# ── DR: hand the public edge over to Front Door ───────────────────────────────
# Both settings below are the SECOND half of the cutover. Do them only after
# app.sometestdemo.in is a CNAME to the Front Door endpoint (see the
# `dns_records` output of infra/platform/frontdoor) — applying them while the A
# record still points here takes the site down.
#
# Order matters:
#   1. apply frontdoor  → gives you the GUID below
#   2. cut DNS over, confirm the site serves through Front Door
#   3. uncomment BOTH lines and re-apply this layer
#
# To roll back to single-region, reverse it: comment these out, re-apply, then
# restore the A record to appgw_public_ip.
#
# allowed_source_prefixes = ["AzureFrontDoor.Backend"] # replaces ["Internet"] above
# frontdoor_id            = "00000000-0000-0000-0000-000000000000"
