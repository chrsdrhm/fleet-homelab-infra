terraform {
  required_version = ">= 1.12.0"

  required_providers {
    okta = {
      source  = "okta/okta"
      version = "~> 7.0"
    }
  }
}

# Authenticates as an OAuth 2.0 service app (client-credentials flow: the provider signs a
# short-lived assertion with the private key and trades it for an access token). The key
# itself never appears in this repo or in tfvars: `okta_private_key_path` is only the
# PATH to a file kept outside the repo. All values live in the gitignored terraform.tfvars.
#
# Applied locally, never from CI: this identity can change who may sign in to Fleet, so
# it stays out of the AWS pipeline's reach (and Okta has no keyless federation for it).
provider "okta" {
  org_name       = var.okta_org_name
  base_url       = var.okta_base_url
  client_id      = var.okta_client_id
  private_key_id = var.okta_private_key_id
  private_key    = pathexpand(var.okta_private_key_path)
  scopes         = var.okta_scopes
}
