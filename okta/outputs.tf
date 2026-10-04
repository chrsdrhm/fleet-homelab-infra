output "entity_id" {
  description = "Fleet's Entity ID. Goes in Fleet's SSO settings."
  value       = local.fleet_url
}

# Contains the org name and app ID, so it is kept out of the plan output and the repo.
# Read it with: terraform output -raw metadata_url | pbcopy
output "metadata_url" {
  description = "The Okta app's PUBLIC SAML metadata URL. Goes in Fleet's SSO settings."
  # Not the provider's `metadata_url` attribute: that is the management-API URL
  # (/api/v1/apps/<id>/sso/saml/metadata), which needs credentials and answers 403 to
  # Fleet's anonymous fetch. The public form uses the app's entity key.
  value     = "https://${var.okta_org_name}.${var.okta_base_url}/app/${okta_app_saml.fleet.entity_key}/sso/saml/metadata"
  sensitive = true
}
