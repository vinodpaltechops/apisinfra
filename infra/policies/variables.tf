variable "mg_ids" {
  description = "Management group IDs from the management-groups layer."
  type        = map(string)
}

variable "allowed_locations" {
  description = "List of approved Azure regions."
  type        = list(string)
  default     = ["eastus2", "centralus"]   # US pair — adjust for your org
}
