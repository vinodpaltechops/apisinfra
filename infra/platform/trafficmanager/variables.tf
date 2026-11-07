variable "org_name" {
  type    = string
  default = "vinorg"
}

variable "location" {
  description = "Region for the metadata resource group ONLY. Traffic Manager is global and answers queries from Azure's DNS edge regardless of this value."
  type        = string
  default     = "southindia"
}

variable "primary_location" {
  description = "Region of the primary App Gateway. Recorded on the endpoint; only read by Performance routing, which this profile does not use."
  type        = string
  default     = "southindia"
}

variable "dr_location" {
  description = "Region of the DR App Gateway. Must match dr_location in the connectivity layer."
  type        = string
  default     = "indiasouthcentral"
}

variable "app_fqdn" {
  description = "Public hostname of the application. Used only to print the DNS record and verification commands — the dns layer owns the record itself, and health probes no longer carry this name."
  type        = string
}

variable "health_hostname" {
  description = <<-EOT
    Sent as the Host header on every health probe. Must be a hostname that has a
    route on the gateway returning 200 for the probe path — in this stack, the
    platform health route in k8s/gitops/platform/agc-gateway (values: health
    .hostname). Keep the two identical: a mismatch gets a 404 from the gateway
    and degrades every endpoint while the app is perfectly healthy.

    It needs no DNS record. Traffic Manager names the host itself, so the probe
    never resolves it.
  EOT
  type        = string
}

variable "enable_dr_endpoint" {
  description = <<-EOT
    Add the DR gateway as the priority-2 endpoint.

    false = a profile with a single endpoint. Useful in two situations: applying
    this layer before the DR region exists, and deliberately parking DR without
    tearing the profile down. In both cases the public endpoint keeps serving
    from the primary, so toggling this is not a user-visible event.
  EOT
  type        = bool
  default     = true
}

variable "ttl" {
  description = "Seconds clients may cache the DNS answer — half the failover time. 30 is the practical floor; client-side caching, not this value, is what usually dominates."
  type        = number
  default     = 30
}

variable "health_probe_path" {
  description = "Must be the app's real health endpoint. Probing / would report healthy whenever nginx serves an error page — a failover that never triggers is worse than no failover, because you believe you have one."
  type        = string
  default     = "/healthz"
}

variable "health_probe_protocol" {
  description = "HTTP or HTTPS (Traffic Manager spells these in caps). Must match health_probe_port and what the gateways actually listen on."
  type        = string
  default     = "HTTP"
}

variable "health_probe_port" {
  type    = number
  default = 80
}

variable "health_probe_interval_seconds" {
  description = "30 standard, or 10 for fast probing (billed separately). With tolerated_number_of_failures = 3 this sets the detection window: 30s gives ~2 minutes."
  type        = number
  default     = 30
}

variable "tolerated_number_of_failures" {
  description = "Consecutive failures before traffic moves. Lower it and a transient blip moves a whole region — which DNS failover recovers from badly, because clients keep the old answer while it flaps."
  type        = number
  default     = 3
}

variable "common_tags" {
  type    = map(string)
  default = {}
}
