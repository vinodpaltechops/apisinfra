# No org_name: the only names this layer creates (state account + resource
# group) come from infra/backend.json, shared with every other layer.
variable "location" {
  description = "Primary Azure region for all resources."
  type        = string
  default     = "southindia"
}
