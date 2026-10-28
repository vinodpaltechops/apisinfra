variable "org_name" {
  type = string
}

variable "resource_group_name" {
  description = "Traffic Manager is a GLOBAL resource. The resource group's region only records where its metadata lives and has no bearing on which endpoint answers a query."
  type        = string
}

variable "endpoints" {
  description = <<-EOT
    Regional endpoints keyed by a static label:

      {
        primary = { target = "<agw public ip>", priority = 1, location = "southindia" }
        dr      = { target = "<agw public ip>", priority = 2, location = "indiasouthcentral" }
      }

    priority 1 takes ALL traffic while its probe passes; 2 is the standby. Two
    endpoints at the same priority is rejected by Azure — priorities must be
    unique within a profile.

    MAP with static keys, never keyed on target — the gateway public IPs are
    apply-time attributes and for_each keys must be known at plan time.

    Removing the `dr` entry is the clean way to stand DR down: the profile and
    its DNS name survive, so the public endpoint keeps working throughout.
  EOT
  type = map(object({
    target   = string
    priority = number
    location = string
    enabled  = optional(bool, true)
  }))

  validation {
    condition     = length([for e in var.endpoints : e if e.priority < 1 || e.priority > 1000]) == 0
    error_message = "Traffic Manager endpoint priority must be between 1 and 1000."
  }

  validation {
    condition     = length(distinct([for e in var.endpoints : e.priority])) == length(var.endpoints)
    error_message = "Endpoint priorities must be unique — Azure rejects a Priority profile with two endpoints at the same priority."
  }
}

variable "probe_host_header" {
  description = <<-EOT
    Sent as the `host` header on every health probe, and it must be the
    application's real FQDN.

    Not optional in this stack, despite the null default: the App Gateway
    listener is host-based, so a probe carrying the default `Host: <target ip>`
    gets a 404 and marks every endpoint Degraded while the app is perfectly
    healthy. Null only exists for a future origin that is not host-bound.
  EOT
  type        = string
  default     = null
}

variable "ttl" {
  description = "Seconds clients may cache the answer. Half the failover time; the rest is probe detection. A floor, not a guarantee — resolvers and browsers routinely cache longer, and some ignore TTL entirely."
  type        = number
  default     = 30

  validation {
    condition     = var.ttl >= 0 && var.ttl <= 2147483647
    error_message = "ttl must be between 0 and 2147483647 seconds."
  }
}

variable "health_probe_path" {
  description = "Probed on every endpoint. Must be the app's real health endpoint — probing / would report healthy whenever nginx serves an error page."
  type        = string
  default     = "/healthz"
}

variable "health_probe_protocol" {
  description = "HTTPS matches how real traffic arrives, but requires a :443 listener on both gateways — which do not have one while enable_https = false. HTTP until the certificate exists."
  type        = string
  default     = "HTTP"

  validation {
    condition     = contains(["HTTP", "HTTPS", "TCP"], var.health_probe_protocol)
    error_message = "health_probe_protocol must be HTTP, HTTPS or TCP (Traffic Manager spells these in caps, unlike Front Door)."
  }
}

variable "health_probe_port" {
  description = "Must match the protocol: 80 for HTTP, 443 for HTTPS. Probing 443 against a gateway with no HTTPS listener degrades every endpoint."
  type        = number
  default     = 80
}

variable "health_probe_interval_seconds" {
  description = "30 (standard) or 10 (fast probing, billed separately). Detection window = interval x (tolerated_number_of_failures + 1)."
  type        = number
  default     = 30

  validation {
    condition     = contains([10, 30], var.health_probe_interval_seconds)
    error_message = "Azure accepts only 10 (fast probing) or 30 seconds."
  }
}

variable "health_probe_timeout_seconds" {
  description = "How long a probe waits for a response. Azure caps this at 10s on a 30s interval, and 9s on a 10s interval."
  type        = number
  default     = 10

  validation {
    condition     = var.health_probe_timeout_seconds >= 5 && var.health_probe_timeout_seconds <= 10
    error_message = "timeout must be between 5 and 10 seconds (and at most 9 when interval is 10)."
  }
}

variable "tolerated_number_of_failures" {
  description = "Consecutive probe failures before an endpoint is Degraded and traffic moves. 3 at a 30s interval is ~2 minutes — short enough to matter, long enough that one blip does not move a region."
  type        = number
  default     = 3

  validation {
    condition     = var.tolerated_number_of_failures >= 0 && var.tolerated_number_of_failures <= 9
    error_message = "tolerated_number_of_failures must be between 0 and 9."
  }
}

variable "expected_status_code_ranges" {
  description = "Probe responses counted as healthy. Kept tight at 200-299: the App Gateway answers 404 for an unmatched host and 502 when its backend pool is empty, and both MUST count as failures."
  type        = list(string)
  default     = ["200-299"]
}

variable "tags" {
  type    = map(string)
  default = {}
}
