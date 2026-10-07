# Who may sign in to Fleet, and with which role, is decided by membership of these two
# groups. Membership is not managed by Terraform: it is set by hand in the
# Okta console and never read or written here. Do not add okta_group_memberships.
resource "okta_group" "fleet_admins" {
  name        = "Fleet Admins"
  description = "Members sign in to Fleet with the global admin role"
}

resource "okta_group" "fleet_observers" {
  name        = "Fleet Observers"
  description = "Members sign in to Fleet with the global observer role"
}

locals {
  fleet_url = "https://${var.fleet_subdomain}"

  # Admin wins if someone is in both groups, so the assertion carries exactly one value
  # (Fleet silently takes the LAST of several). Anyone in neither group gets the
  # deliberately INVALID value "unassigned": only the two groups are meant to be assigned
  # to the app, but a user assigned to it directly would otherwise arrive with an empty
  # role, which Fleet treats as "not set" (parseRole, server/fleet/sessions.go): an
  # existing user silently keeps their old role and a new one becomes observer. An
  # unrecognized value makes Fleet reject the login instead ("invalid role: unassigned")
  # for new and existing users alike, with no account created or changed.
  role_expression = "isMemberOfGroupName(\"${okta_group.fleet_admins.name}\") ? \"admin\" : (isMemberOfGroupName(\"${okta_group.fleet_observers.name}\") ? \"observer\" : \"unassigned\")"
}

resource "okta_app_saml" "fleet" {
  label = "Fleet"

  sso_url     = "${local.fleet_url}/api/v1/fleet/sso/callback"
  recipient   = "${local.fleet_url}/api/v1/fleet/sso/callback"
  destination = "${local.fleet_url}/api/v1/fleet/sso/callback"
  audience    = local.fleet_url

  # Fleet uses the NameID VALUE as the user's email and ignores the format.
  subject_name_id_template = "$${user.email}"
  subject_name_id_format   = "urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress"

  # Required by Okta for custom SAML apps. Fleet does not inspect it.
  authn_context_class_ref = "urn:oasis:names:tc:SAML:2.0:ac:classes:PasswordProtectedTransport"

  response_signed     = true
  assertion_signed    = true
  signature_algorithm = "RSA_SHA256"
  digest_algorithm    = "SHA256"

  attribute_statements {
    name   = "FLEET_JIT_USER_ROLE_GLOBAL"
    type   = "EXPRESSION"
    values = [local.role_expression]
  }

  # Fleet reads a new user's display name from the first attribute named name,
  # displayname or cn (among others).
  attribute_statements {
    name   = "name"
    type   = "EXPRESSION"
    values = ["user.displayName"]
  }

  # Keeps the service app's scopes to apps + groups: without this the provider also
  # reads and assigns the app's sign-on policy, which needs policy scopes. The app uses
  # the org's default sign-on policy.
  skip_authentication_policy = true
}

resource "okta_app_group_assignments" "fleet" {
  app_id = okta_app_saml.fleet.id

  group {
    id = okta_group.fleet_admins.id
  }

  group {
    id = okta_group.fleet_observers.id
  }
}
