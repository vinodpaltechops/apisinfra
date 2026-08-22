# Committed + CI-loaded (see .gitignore `!*.auto.tfvars`). NO SECRETS here.
#
# Mirrors infra/platform/appgw/appgw.auto.tfvars. Values that MUST match the
# primary gateway are marked; a mismatch produces a DR region that looks healthy
# and serves the wrong thing.

app_fqdn = "app.sometestdemo.in" # MUST match the primary gateway

waf_mode = "Prevention"

# Only Front Door may reach this gateway. See variables.tf before widening.
allowed_source_prefixes = ["AzureFrontDoor.Backend"]

# ── Two-pass bootstrap ────────────────────────────────────────────────────────
# Leave this commented on the FIRST apply — Front Door does not exist yet, and
# an X-Azure-FDID rule with no Front Door blocks everything including the health
# probes. After applying infra/platform/frontdoor, uncomment it with that
# layer's `frontdoor_id` output and re-apply this layer.
#
# frontdoor_id = "00000000-0000-0000-0000-000000000000"

# ── TLS — the SAME certificate as the primary gateway ─────────────────────────
# Both gateways serve app_fqdn, so both present a certificate for it. Sharing
# one vault entry means one renewal; a per-region copy is how a certificate ends
# up expired in exactly the region you fail over to.
#
# Unversioned secret URL, so a rotation is picked up without a Terraform change.
enable_https           = true
http_redirect_to_https = false

ssl_certificate_key_vault_secret_id = "https://kv-dev-lab-d5f9ug.vault.azure.net/secrets/app-tls"
key_vault_id                        = "/subscriptions/9a80f875-0d94-48c9-9502-c7814477ffad/resourceGroups/rg-spoke-dev-vinorg-001/providers/Microsoft.KeyVault/vaults/kv-dev-lab-d5f9ug"

# Dedicated gateway subnet inside the DR spoke. 10.5.1-4.0/24 are the spoke's
# own snet-* ranges, so the gateway takes .7 to mirror the hub's 10.0.7.0/24.
subnet_address_prefix = "10.5.7.0/24"
