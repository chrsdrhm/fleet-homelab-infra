variable "fleet_subdomain" {
  description = "Fully-qualified domain name Fleet will be served on, e.g. fleet.example.com"
  type        = string
}

variable "fleet_license_key" {
  description = "Fleet Premium license key"
  type        = string
  sensitive   = true
}

variable "rds_snapshot_identifier" {
  description = "Aurora cluster snapshot to restore from on apply. Leave null for a fresh empty database (first-ever apply); set it to restore state after a teardown (see scripts/up.sh)."
  type        = string
  default     = null
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token with Zone > DNS > Edit on cloudflare_zone_name only"
  type        = string
  sensitive   = true
}

variable "cloudflare_zone_name" {
  description = "Apex zone in Cloudflare that fleet_subdomain lives under, e.g. example.com"
  type        = string
}
