variable "location" {
  type = string
}

# Availability zones for zone-redundant resources (Public IP, Firewall).
# Leave empty for regions without zone support (e.g. southindia) → resources
# deploy as regional. Set to ["1","2","3"] in a zone-capable region
# (e.g. centralindia) for zone redundancy.
variable "availability_zones" {
  type    = list(string)
  default = []
}