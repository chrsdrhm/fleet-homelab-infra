# The three values Fleet's GitOps config needs (see the GitOps repo's default.yml).
output "entity_id" {
  value = one(azuread_application.fleet.identifier_uris)
}

output "metadata_url" {
  description = "App Federation Metadata URL -> metadata_url in Fleet's sso_settings. Embeds tenant/app IDs, so treat as private."
  # Built from tenant + app IDs (the standard portal format, verified to serve
  # SAML metadata): the provider's saml_metadata_url attribute comes back empty
  # for a custom SAML app, so it can't be used here.
  value     = "https://login.microsoftonline.com/${var.tenant_id}/federationmetadata/2007-06/federationmetadata.xml?appid=${azuread_application.fleet.client_id}"
  sensitive = true
}
