# Committed + CI-loaded (see .gitignore `!*.auto.tfvars`). NO SECRETS here.
#
# CHANGE app_fqdn to your real GoDaddy domain before applying — it is baked
# into the listener, the Host header sent to the ingress, and (later) the TLS
# certificate subject.
app_fqdn = "app.sometestdemo.in"

# Must match service.beta.kubernetes.io/azure-load-balancer-ipv4 in
# k8s/platform/ingress-nginx-values.yaml.
ingress_internal_ip = "10.1.2.5"

waf_mode = "Prevention"

# ["Internet"] = a genuinely public site. While testing you can narrow this to
# your own ISP range, e.g. ["163.223.165.0/24"], and widen it once it works.
allowed_source_prefixes = ["Internet"]
