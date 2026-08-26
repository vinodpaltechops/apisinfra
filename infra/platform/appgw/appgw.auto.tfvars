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
enable_https = false

# Only read when enable_https = true.
#   true  — :80 permanently redirects to :443 (right answer for a public site)
#   false — :80 keeps serving the app too, so http:// and https:// both work
http_redirect_to_https = false

# ── STALE VAULT REFERENCE — read before flipping enable_https back to true ────
# The two IDs below name kv-dev-lab-d5f9ug, the vault from a PREVIOUS
# deployment. That vault no longer exists: the whole stack is currently torn
# down (only rg-tfstate-vinorg-001 remains).
#
# The keyvault module names the vault kv-${env}-lab-${random_string.suffix}
# (infra/modules/keyvault/main.tf), so a fresh apply generates a DIFFERENT
# 6-character suffix. Pointing a gateway at the old name fails when it tries to
# fetch the certificate, and the error surfaces as
# ApplicationGatewayKeyVaultSecretAccessDenied — which reads like an RBAC
# problem, not a wrong-name problem.
#
# So enable_https is false for the rebuild. That is a COMPLETE configuration,
# not a broken one: the gateway serves the app on :80 and needs no certificate
# at all. After the dev landing zone applies:
#
#   1. terraform -chdir=infra/landing-zones/dev output key_vault_uri
#   2. import the cert into THAT vault (see docs/public-endpoint.md — it must be
#      done from inside the VNet, i.e. from the mgmt VM)
#   3. replace both IDs here AND in appgw-dr.auto.tfvars with the new name
#   4. set enable_https = true and re-apply both gateway layers
#
# Both files must be updated together — the two gateways share one certificate
# precisely so there is only ever one renewal to remember.
#
# Import the certificate into Key Vault first (portal or
# `az keyvault certificate import`, from inside the VNet — the vault has no
# public endpoint), then uncomment both. Use the UNVERSIONED secret URL so the
# gateway follows rotations automatically.
#
# The module creates its own managed identity and grants it Key Vault Secrets
# User on key_vault_id — do not create that role assignment by hand as well, or
# the apply fails with RoleAssignmentExists.
#
ssl_certificate_key_vault_secret_id = "https://kv-dev-lab-o6xycn.vault.azure.net/secrets/app-tls"
key_vault_id                        = "/subscriptions/9a80f875-0d94-48c9-9502-c7814477ffad/resourceGroups/rg-spoke-dev-vinorg-001/providers/Microsoft.KeyVault/vaults/kv-dev-lab-o6xycn"

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
