terraform {
  required_version = ">= 1.12.0"

  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
  }
}

# Authenticates with the Azure CLI session (`az login`) — no stored secret.
# Applied locally by a tenant admin, never from CI: this identity can change
# who may sign in to Fleet, so it stays out of the AWS pipeline's reach.
provider "azuread" {
  tenant_id = var.tenant_id
}
