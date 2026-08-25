# Committed + CI-loaded (see .gitignore `!*.auto.tfvars`). NO SECRETS here.
#
# Mirrors infra/platform/appgw/appgw.auto.tfvars. Values that MUST match the
# primary gateway are marked; a mismatch produces a DR region that looks healthy
# and serves the wrong thing.

app_fqdn = "app.sometestdemo.in" # MUST match the primary gateway

waf_mode = "Prevention"

# Only Front Door may reach this gateway. See variables.tf before widening.
# ── Internet, because Front Door does not exist on this subscription ──────────
# Azure forbids Front Door on Free Trial subscriptions
# (quotaId FreeTrial_2014-09-01): "Free Trial and Student account is forbidden
# for Azure Frontdoor resources". The frontdoor layer is therefore commented out
# of the deploy pipeline.
#
# ["AzureFrontDoor.Backend"] — the correct value WITH Front Door — would leave
# this gateway admitting traffic only from a service that is not deployed, i.e.
# unreachable by anything at all. Failover is tested here by moving the DNS A
# record between the two gateway IPs, so this one has to be reachable.
#
# PUT THIS BACK to ["AzureFrontDoor.Backend"] at the same time you re-enable the
# frontdoor layer and set frontdoor_id. Leaving it as Internet once Front Door
# is live means anyone who finds the origin IP bypasses Front Door's WAF,
# routing and failover entirely.
allowed_source_prefixes = ["Internet"]

# ── Two-pass bootstrap ────────────────────────────────────────────────────────
# Leave this commented on the FIRST apply — Front Door does not exist yet, and
# an X-Azure-FDID rule with no Front Door blocks everything including the health
# probes. After applying infra/platform/frontdoor, uncomment it with that
# layer's `frontdoor_id` output and re-apply this layer.
#
# frontdoor_id = "00000000-0000-0000-0000-000000000000"

# ── STALE VAULT REFERENCE — read before flipping enable_https back to true ────
# The IDs below name kv-dev-lab-d5f9ug, the vault from a PREVIOUS deployment,
# which no longer exists — the stack is currently torn down.
#
# The keyvault module names the vault kv-${env}-lab-${random_string.suffix}, so
# a fresh apply generates a DIFFERENT suffix. A gateway pointed at the old name
# fails fetching the certificate with ApplicationGatewayKeyVaultSecretAccessDenied,
# which reads like an RBAC problem rather than a wrong name.
#
# enable_https is therefore false for the rebuild, matching appgw.auto.tfvars.
# HTTP-only is a complete configuration here, not a broken one.
#
# Turn TLS back on in BOTH files together, after the dev landing zone exists:
#   1. terraform -chdir=infra/landing-zones/dev output key_vault_uri
#   2. import the cert into THAT vault, from the mgmt VM (docs/public-endpoint.md)
#   3. replace both IDs here and in appgw.auto.tfvars
#   4. enable_https = true, re-apply both gateway layers
#
# NOTE for Front Door: with HTTP-only origins, set forwarding_protocol =
# "HttpOnly" in frontdoor.auto.tfvars for the initial test, or Front Door tries
# 443 against a gateway with no HTTPS listener and every origin reports
# unhealthy. Move both to HTTPS together once the certificate is in place.

# ── TLS — the SAME certificate as the primary gateway ─────────────────────────
# Both gateways serve app_fqdn, so both present a certificate for it. Sharing
# one vault entry means one renewal; a per-region copy is how a certificate ends
# up expired in exactly the region you fail over to.
#
# Unversioned secret URL, so a rotation is picked up without a Terraform change.
enable_https           = false
http_redirect_to_https = false

ssl_certificate_key_vault_secret_id = "https://kv-dev-lab-d5f9ug.vault.azure.net/secrets/app-tls"
key_vault_id                        = "/subscriptions/9a80f875-0d94-48c9-9502-c7814477ffad/resourceGroups/rg-spoke-dev-vinorg-001/providers/Microsoft.KeyVault/vaults/kv-dev-lab-d5f9ug"

# Dedicated gateway subnet inside the DR spoke. 10.5.1-4.0/24 are the spoke's
# own snet-* ranges, so the gateway takes .7 to mirror the hub's 10.0.7.0/24.
subnet_address_prefix = "10.5.7.0/24"
