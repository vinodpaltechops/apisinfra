variable "org_name" {
  type = string
}

variable "resource_group_name" {
  description = "Front Door is a GLOBAL resource. The resource group's region only records where its metadata lives and has no bearing on where traffic is served from."
  type        = string
}

variable "app_fqdn" {
  description = "Public hostname, e.g. app.sometestdemo.in. Becomes the Front Door custom domain AND the Host header sent to every origin — the App Gateway listener and the Ingress rule are both host-based, so it must match them exactly."
  type        = string
}

variable "sku_name" {
  description = <<-EOT
    Standard_AzureFrontDoor (default) covers global routing, failover, custom
    domains and managed certificates — everything this DR design needs.

    Premium_AzureFrontDoor adds managed WAF rule sets, bot protection and
    Private Link to origins. The OWASP managed rules are already running on
    each App Gateway, so Premium would mostly be paying twice for the same
    inspection; its real draw is Private Link, which would let the gateways
    drop their public IPs entirely.
  EOT
  type        = string
  default     = "Standard_AzureFrontDoor"

  validation {
    condition     = contains(["Standard_AzureFrontDoor", "Premium_AzureFrontDoor"], var.sku_name)
    error_message = "sku_name must be Standard_AzureFrontDoor or Premium_AzureFrontDoor."
  }
}

variable "origins" {
  description = <<-EOT
    Regional origins keyed by a static label:

      {
        primary = { host_name = "<agw public ip>", priority = 1, enabled = true }
        dr      = { host_name = "<agw public ip>", priority = 2, enabled = true }
      }

    priority 1 takes ALL traffic while healthy; 2 is the standby. Two origins at
    the same priority is active-active, which this design is not sized for.

    MAP with static keys, never keyed on host_name — the gateway public IPs are
    apply-time attributes and for_each keys must be known at plan time.

    Removing the `dr` entry is the clean way to stand DR down: the origin group,
    the route and the custom domain survive, so the public endpoint keeps
    working throughout.
  EOT
  type = map(object({
    host_name = string
    priority  = number
    enabled   = optional(bool, true)
  }))

  validation {
    condition     = length([for o in var.origins : o if o.priority < 1 || o.priority > 5]) == 0
    error_message = "Front Door origin priority must be between 1 and 5."
  }
}

variable "health_probe_path" {
  description = "Probed on every origin. Must be the app's real health endpoint — probing / would report healthy whenever nginx serves an error page."
  type        = string
  default     = "/healthz"
}

variable "health_probe_protocol" {
  description = "Https matches how real traffic reaches the origin. Http avoids the TLS handshake on every probe from every PoP, at the cost of not exercising the origin's certificate."
  type        = string
  default     = "Https"

  validation {
    condition     = contains(["Http", "Https"], var.health_probe_protocol)
    error_message = "health_probe_protocol must be Http or Https."
  }
}

variable "health_probe_interval_seconds" {
  description = "Seconds between probes FROM EACH EDGE POP — the aggregate rate against /healthz is many times higher than 1/interval. With sample_size 4 this sets the failover detection window (30s x 4 = ~2 min)."
  type        = number
  default     = 30
}

variable "forwarding_protocol" {
  description = "How Front Door reaches the origin. HttpsOnly keeps the edge-to-origin leg encrypted. MatchRequest would forward plain HTTP for plain-HTTP clients, leaving that leg in the clear across the public internet path to the gateway."
  type        = string
  default     = "HttpsOnly"

  validation {
    condition     = contains(["HttpOnly", "HttpsOnly", "MatchRequest"], var.forwarding_protocol)
    error_message = "forwarding_protocol must be HttpOnly, HttpsOnly or MatchRequest."
  }
}

variable "origin_certificate_name_check_enabled" {
  description = "Must stay false while origins are raw public IPs — no certificate can match an IP, and enabling it 503s every request. See the long note in main.tf for how to turn it on properly."
  type        = bool
  default     = false
}

variable "response_timeout_seconds" {
  description = "Kept above the App Gateway's 30s backend timeout so the gateway's timeout is always the one that fires, and its more specific error is what surfaces."
  type        = number
  default     = 60
}

variable "tags" {
  type    = map(string)
  default = {}
}
