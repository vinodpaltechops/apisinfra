variable "env" {
  type = string
}

variable "role" {
  description = "VM role, used in the name: vm-<role>-<env>-001. 'jump' = private tester, 'mgmt' = public bastion-replacement."
  type        = string
  default     = "jump"
}

variable "enable_public_ip" {
  description = "Attach a public IP + a NIC-level NSG (SSH from ssh_source_prefix only). Use for a public entry/bastion-replacement VM; keep false for a private jump."
  type        = bool
  default     = false
}

variable "ssh_source_prefix" {
  description = "CIDR allowed to SSH in when enable_public_ip = true (your home/ISP public IP). Ignored for private VMs."
  type        = string
  default     = null
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
