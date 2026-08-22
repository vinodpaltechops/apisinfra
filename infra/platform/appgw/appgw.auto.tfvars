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
enable_https = true

# Only read when enable_https = true.
#   true  — :80 permanently redirects to :443 (right answer for a public site)
#   false — :80 keeps serving the app too, so http:// and https:// both work
http_redirect_to_https = false

# Import the certificate into Key Vault first (portal or
# `az keyvault certificate import`, from inside the VNet — the vault has no
# public endpoint), then uncomment both. Use the UNVERSIONED secret URL so the
# gateway follows rotations automatically.
#
# The module creates its own managed identity and grants it Key Vault Secrets
# User on key_vault_id — do not create that role assignment by hand as well, or
# the apply fails with RoleAssignmentExists.
#
ssl_certificate_key_vault_secret_id = "https://kv-dev-lab-d5f9ug.vault.azure.net/secrets/app-tls"
key_vault_id                        = "/subscriptions/9a80f875-0d94-48c9-9502-c7814477ffad/resourceGroups/rg-spoke-dev-vinorg-001/providers/Microsoft.KeyVault/vaults/kv-dev-lab-d5f9ug"

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
