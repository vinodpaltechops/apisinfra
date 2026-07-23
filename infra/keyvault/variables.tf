variable "location" {
  type    = string
  default = "southindia"
}

# Public IP(s) allowed through the Key Vault data-plane firewall so Terraform
# (running from your workstation) can seed secrets. The vault stays reachable
# only from these IPs + the private endpoint. Set in terraform.tfvars (gitignored)
# so your IP isn't committed. Get yours with: curl -s ifconfig.me
variable "allowed_ip_rules" {
  type    = list(string)
  default = []
}