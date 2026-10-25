# Committed + CI-loaded (see .gitignore `!*.auto.tfvars`). NO SECRETS here.

org_name = "vinorg"
location = "southindia" # metadata resource group only — Azure DNS is global

zone_name = "sometestdemo.in"

# MUST match app_fqdn in appgw, appgw-dr and trafficmanager. The record itself
# is built in main.tf, targeting the Traffic Manager profile's FQDN.
app_fqdn = "app.sometestdemo.in"
app_ttl  = 600

# ── Copied from the GoDaddy zone export ───────────────────────────────────────
# Deliberately NOT carried over:
#   @      A      "WebsiteBuilder Site" — a GoDaddy-internal placeholder, not an
#                 IP. There is nothing to copy: once nameservers move, the apex
#                 no longer serves the GoDaddy Website Builder site. Add an A
#                 record under a_records["@"] if the apex should resolve.
#   www    CNAME  @ — points at the apex above, so it would dangle. Re-add it
#                 under cname_records once the apex has a target.
#   _domainconnect  CNAME — GoDaddy's one-click-setup hook; meaningless outside
#                 their nameservers.
#   SOA / NS — Azure generates both.

txt_records = {
  # Looks like a leftover manual ACME challenge for app. Harmless to keep; drop
  # it if no certificate is issued that way.
  "_acme-challenge.app" = {
    ttl    = 600
    values = ["5RFk8VXPZEkfpq22Lqnh7FlWi3jNlhhvXr0P765MzQY"]
  }
  "_dmarc" = {
    ttl    = 3600
    values = ["v=DMARC1; p=quarantine; adkim=r; aspf=r; rua=mailto:dmarc_rua@onsecureserver.net;"]
  }
}
