variable "tenant_id" {
  description = "Entra directory (tenant) ID. Kept out of Git; set in terraform.tfvars."
  type        = string
}

variable "fleet_subdomain" {
  description = "FQDN Fleet is served on. Must sit under a verified domain of the tenant (Entra rejects other identifier URIs)."
  type        = string
}

variable "fleet_admins" {
  description = "UPNs of users who get the Fleet global admin role. Managed here, never by hand in the portal."
  type        = set(string)

  validation {
    condition     = length(var.fleet_admins) > 0
    error_message = "At least one admin is required, or nobody can administer Fleet through SSO."
  }
}

variable "fleet_observers" {
  description = "UPNs of users who get the read-only observer role."
  type        = set(string)
  default     = []

  # Fleet reads the role attribute as a list and silently takes the LAST value
  # (parseRole in server/fleet/sessions.go). The order Entra emits assigned roles in
  # isn't ours to control, so a user holding both roles gets an arbitrary one.
  # Making the overlap a plan-time error removes that failure mode entirely.
  validation {
    condition = length(setintersection(
      toset([for u in var.fleet_admins : lower(u)]),
      toset([for u in var.fleet_observers : lower(u)]),
    )) == 0
    error_message = "A user must not be in both fleet_admins and fleet_observers: Fleet takes the last role value in the assertion, and the order isn't controllable."
  }
}
