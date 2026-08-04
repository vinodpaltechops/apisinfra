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

variable "admin_username" {
  type    = string
  default = "azureadmin"
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key used for the initial admin_ssh_key (~ is expanded)."
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "vm_size" {
  type    = string
  default = "Standard_B2ats_v2" # B2s unavailable in southindia; this one has capacity
}

variable "tags" {
  type    = map(string)
  default = {}
}
