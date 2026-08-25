variable "org_name" {
  type    = string
  default = "vinorg"
}

variable "location" {
  description = "Region for the metadata resource group ONLY. Front Door itself is global and serves from Azure's edge PoPs regardless of this value."
  type        = string
  default     = "southindia"
}

variable "app_fqdn" {
  description = "Public hostname. Must match app_fqdn in BOTH appgw layers — it is the Host header sent to the origins, and both gateways listen host-based."
  type        = string
}

variable "sku_name" {
  description = "Standard covers routing, failover, custom domains and managed certificates. Premium adds managed WAF (already running on each App Gateway) and Private Link to origins."
  type        = string
  default     = "Standard_AzureFrontDoor"
}

variable "enable_dr_origin" {
  description = <<-EOT
    Add the DR gateway as the priority-2 origin.

    false = Front Door with a single origin. Useful in two situations: applying
    this layer before the DR region exists, and deliberately parking DR without
    tearing Front Door down. In both cases the public endpoint keeps serving
    from the primary, so toggling this is not a user-visible event.
  EOT
  type        = bool
  default     = true
}

variable "health_probe_path" {
  description = "Must be the app's real health endpoint. Probing / would report healthy whenever nginx serves an error page — a failover that never triggers is worse than no failover, because you believe you have one."
  type        = string
  default     = "/healthz"
}

variable "health_probe_protocol" {
  type    = string
  default = "Https"
}

variable "health_probe_interval_seconds" {
  description = "Per edge PoP. With sample_size 4 / 3 required, this sets the detection window: 30s gives ~2 minutes before failover. Lower it and transient blips start flapping traffic between regions."
  type        = number
  default     = 30
}

variable "forwarding_protocol" {
  description = "HttpsOnly keeps the edge-to-origin leg encrypted."
  type        = string
  default     = "HttpsOnly"
}

variable "common_tags" {
  type    = map(string)
  default = {}
}
