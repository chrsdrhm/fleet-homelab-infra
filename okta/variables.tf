variable "fleet_subdomain" {
  description = "FQDN Fleet is served on. Becomes the SAML audience (Entity ID) and the base of the single sign-on URL."
  type        = string
}

variable "okta_org_name" {
  description = "Okta org name, the part before .okta.com (for example trial-1234567)."
  type        = string
}

variable "okta_base_url" {
  description = "Okta domain the org lives on."
  type        = string
  default     = "okta.com"
}

variable "okta_client_id" {
  description = "Client ID of the Okta API service app Terraform signs in as."
  type        = string
}

variable "okta_private_key_id" {
  description = "Key ID (kid) of the service app's key, shown in its Public Keys table."
  type        = string
}

variable "okta_private_key_path" {
  description = "Path to the service app's private key file. Keep the file outside this repo."
  type        = string
}

variable "okta_scopes" {
  description = "Okta API scopes the service app has been granted and Terraform requests."
  type        = list(string)
  default     = ["okta.apps.manage", "okta.groups.manage"]
}
