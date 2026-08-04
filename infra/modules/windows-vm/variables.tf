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
  description = "Subnet the VM NIC lands in (typically the spoke's snet-app)."
  type        = string
}

variable "admin_password" {
  type      = string
  sensitive = true
}

variable "admin_username" {
  type    = string
  default = "azureadmin"
}

variable "vm_size" {
  type    = string
  default = "Standard_B2ats_v2"
}

variable "tags" {
  type    = map(string)
  default = {}
}
