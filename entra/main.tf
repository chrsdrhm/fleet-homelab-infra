data "azuread_client_config" "me" {}

# Stable IDs for the two app roles (an app role is referenced by GUID).
resource "random_uuid" "role_admin" {}
resource "random_uuid" "role_observer" {}

resource "azuread_application" "fleet" {
  display_name     = "Fleet"
  sign_in_audience = "AzureADMyOrg"                     # single tenant
  identifier_uris  = ["https://${var.fleet_subdomain}"] # = SAML Entity ID; must equal entity_id in Fleet's GitOps config
  owners           = [data.azuread_client_config.me.object_id]

  web {
    # Fleet's SAML assertion consumer service for Fleet users. The second,
    # /mdm/sso/callback path is only for end-user SSO during MDM enrollment.
    redirect_uris = ["https://${var.fleet_subdomain}/api/v1/fleet/sso/callback"]
  }

  # Lets a claims-mapping policy apply to this app without a custom signing key.
  api {
    mapped_claims_enabled = true
  }

  # Fleet's JIT role comes from the SAML attribute FLEET_JIT_USER_ROLE_GLOBAL.
  # These role values are what that attribute carries. Fleet reads a LIST of
  # values for the attribute, so every user must hold exactly one of these.
  app_role {
    id                   = random_uuid.role_admin.result
    value                = "admin"
    display_name         = "Fleet admin"
    description          = "Global admin in Fleet"
    allowed_member_types = ["User"]
    enabled              = true
  }

  app_role {
    id                   = random_uuid.role_observer.result
    value                = "observer"
    display_name         = "Fleet observer"
    description          = "Read-only in Fleet"
    allowed_member_types = ["User"]
    enabled              = true
  }
}

resource "azuread_service_principal" "fleet" {
  client_id                     = azuread_application.fleet.client_id
  preferred_single_sign_on_mode = "saml"
  app_role_assignment_required  = true # only assigned users/groups can sign in
  owners                        = [data.azuread_client_config.me.object_id]

  feature_tags {
    custom_single_sign_on = true # a custom (non-gallery) SAML app
  }
}

resource "azuread_group" "fleet_admins" {
  display_name     = "Fleet Admins"
  security_enabled = true
  owners           = [data.azuread_client_config.me.object_id]
  members          = [data.azuread_client_config.me.object_id]
}

# Group -> role assignment: members of Fleet Admins get the "admin" role,
# which the claims policy below emits as FLEET_JIT_USER_ROLE_GLOBAL=admin.
# (Group assignment to apps needs Entra ID P1; the tenant has it via EMS.)
# To add a read-only user later, assign that USER to the observer role directly,
# and never put anyone in both — two role values makes Fleet reject the login.
resource "azuread_app_role_assignment" "admins" {
  app_role_id         = random_uuid.role_admin.result
  principal_object_id = azuread_group.fleet_admins.object_id
  resource_object_id  = azuread_service_principal.fleet.object_id
}

resource "azuread_claims_mapping_policy" "fleet" {
  display_name = "fleet-jit-role"
  definition = [jsonencode({
    ClaimsMappingPolicy = {
      Version              = 1
      IncludeBasicClaimSet = "true"
      ClaimsSchema = [{
        Source        = "user"
        ID            = "assignedroles"
        SamlClaimType = "FLEET_JIT_USER_ROLE_GLOBAL"
      }]
    }
  })]
}

resource "azuread_service_principal_claims_mapping_policy_assignment" "fleet" {
  claims_mapping_policy_id = azuread_claims_mapping_policy.fleet.id
  service_principal_id     = azuread_service_principal.fleet.id
}

# A SAML app needs a token-signing certificate for Fleet to validate assertions.
# The portal creates one automatically when SAML SSO is switched on; creating the
# app through the API does not, and without one the metadata has no signing key
# and every login fails. Found by checking the metadata, not by Terraform erroring.
# Entra's default lifetime is 3 years — when it nears expiry, re-apply to rotate
# (Fleet re-reads the metadata URL, so there's nothing to change on the Fleet side).
resource "azuread_service_principal_token_signing_certificate" "fleet" {
  service_principal_id = azuread_service_principal.fleet.id
}
