# End-user authentication (plan Task 20 Part A): the person who owns a device signs in
# with Okta while it enrolls. A separate app from the admin one in main.tf, as Fleet's
# setup-experience guide says, so only Fleet users can sign in to Fleet itself. End users
# never get a Fleet account: Fleet stores who they are on the host.

# Who may enroll a device. Membership is set by hand in the Okta console, never here, as
# for the admin groups. Do not add okta_group_memberships.
resource "okta_group" "fleet_device_users" {
  name        = "Fleet Device Users"
  description = "Members can sign in while enrolling a device in Fleet"
}

locals {
  # Its own Entity ID, so neither app's assertions are accepted by the other. The same
  # value Fleet uses for its own Okta end-user app (fleetdm/fleet it-and-security).
  enduser_entity_id = "fleet-end-users"
}

resource "okta_app_saml" "fleet_enduser" {
  label = "Fleet device enrollment"
  logo  = local.app_logo

  sso_url     = "${local.fleet_url}/api/v1/fleet/mdm/sso/callback"
  recipient   = "${local.fleet_url}/api/v1/fleet/mdm/sso/callback"
  destination = "${local.fleet_url}/api/v1/fleet/mdm/sso/callback"
  audience    = local.enduser_entity_id

  # Fleet stores the NameID VALUE as the host's IdP email, and its local part as the
  # username. Anything other than an email gives every device an unusable "email".
  subject_name_id_template = "$${user.email}"
  subject_name_id_format   = "urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress"

  # Required by Okta for custom SAML apps. Fleet does not inspect it.
  authn_context_class_ref = "urn:oasis:names:tc:SAML:2.0:ac:classes:PasswordProtectedTransport"

  response_signed     = true
  assertion_signed    = true
  signature_algorithm = "RSA_SHA256"
  digest_algorithm    = "SHA256"

  # Fleet reads the full name from the first attribute named name, displayname or cn
  # (among others), and on macOS fills in the local account's Full Name with it.
  attribute_statements {
    name   = "name"
    type   = "EXPRESSION"
    values = ["user.displayName"]
  }

  # As for the admin app: the org's default sign-on policy. Fleet's guide recommends a
  # policy that disallows Okta FastPass for Apple automatic enrollment (Okta Verify isn't
  # installed yet then); that needs policy scopes this service app doesn't have.
  skip_authentication_policy = true
}

resource "okta_app_group_assignments" "fleet_enduser" {
  app_id = okta_app_saml.fleet_enduser.id

  group {
    id = okta_group.fleet_device_users.id
  }
}
