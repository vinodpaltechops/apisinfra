variable "env" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "subnet_id" {
  description = "Subnet for the storage private endpoint (typically the spoke's snet-app)."
  type        = string
}

variable "blob_private_dns_zone_id" {
  description = "ID of the shared privatelink.blob zone from the hub (connectivity) layer."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
