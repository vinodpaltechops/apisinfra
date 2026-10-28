variable "org_name" {
  type    = string
  default = "vinorg"
}

variable "subscription_ids" {
  description = <<-EOT
    Map of environment name to subscription ID, for a multi-subscription landing
    zone. Anything omitted falls back to the subscription Terraform is
    authenticated against, which is all a single-subscription stack needs.
    Set via TF_VAR_subscription_ids='{"connectivity":"uuid","dev":"uuid",...}'.
  EOT
  type        = map(string)
  default     = {}
}
