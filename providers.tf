terraform {
  required_version = ">= 1.12.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.37.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"

  # Applied to every taggable resource, including those inside the Fleet
  # modules. Find everything with: Tag Editor / Resource Groups on Project=fleet-lab.
  default_tags {
    tags = {
      Project   = "fleet-lab"
      ManagedBy = "terraform"
    }
  }
}

# Only used to delegate the Fleet subdomain to Route 53 (cloudflare.tf).
# Token scope: Zone > DNS > Edit, on the one zone only.
provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

data "aws_caller_identity" "current" {}
