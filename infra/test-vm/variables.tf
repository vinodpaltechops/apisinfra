variable "location" {
  type    = string
  default = "southindia"
}
variable "admin_password"     {
  type      = string
  sensitive = true   # marks as sensitive — never printed in logs
}