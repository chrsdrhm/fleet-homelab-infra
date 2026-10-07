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

variable "budget_alert_email" {
  description = "Address that receives AWS Budget alerts. Kept out of Git (this repo is public); set in terraform.tfvars."
  type        = string
}

variable "waf_ci_header_value" {
  description = "Secret value of the x-fleet-ci request header. The WAF allows requests carrying it regardless of country, so the GitOps workflow works from GitHub runners outside the US. Held in the gitignored terraform.tfvars and as a GitHub Actions secret; never committed."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.waf_ci_header_value) >= 32
    error_message = "Use a long random value, for example: openssl rand -hex 32."
  }
}

variable "github_owner" {
  description = "GitHub user or organization that owns this repo."
  type        = string
}

variable "github_owner_id" {
  description = "Numeric GitHub owner ID, part of the immutable OIDC subject format."
  type        = string
}

variable "github_repo_id" {
  description = "Numeric GitHub repository ID, part of the immutable OIDC subject format. Changes if the repo is ever recreated."
  type        = string
}
