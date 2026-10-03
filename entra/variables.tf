variable "tenant_id" {
  description = "Entra directory (tenant) ID. Kept out of Git; set in terraform.tfvars."
  type        = string
}

variable "fleet_subdomain" {
  description = "FQDN Fleet is served on. Must sit under a verified domain of the tenant (Entra rejects other identifier URIs)."
  type        = string
}
