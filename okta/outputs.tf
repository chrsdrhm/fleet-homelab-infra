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

output "enduser_entity_id" {
  description = "Fleet's Entity ID for end-user authentication. The GitOps repo's end_user_authentication uses the same value."
  value       = local.enduser_entity_id
}

# Like metadata_url: holds the org name and app key, so it stays out of the plan and the
# repo. It becomes the GitOps repo's FLEET_END_USER_OKTA_METADATA_URL secret.
output "enduser_metadata_url" {
  description = "The end-user app's PUBLIC SAML metadata URL."
  value       = "https://${var.okta_org_name}.${var.okta_base_url}/app/${okta_app_saml.fleet_enduser.entity_key}/sso/saml/metadata"
  sensitive   = true
}
