variable "org_name" {
  type    = string
  default = "vinorg"
}

variable "subscription_ids" {
  description = "Map of environment name to subscription ID."
  type        = map(string)
  # Set via TF_VAR_subscription_ids='{"connectivity":"uuid","dev":"uuid",...}'
}
