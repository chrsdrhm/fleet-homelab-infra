# Same state bucket as the AWS stack, separate key: Okta changes and AWS
# changes never share a state file or a lock.
terraform {
  backend "s3" {
    # `bucket` is supplied at init time from the gitignored backend.hcl (it embeds the AWS
    # account ID, kept out of this public repo): terraform init -backend-config=backend.hcl
    key          = "fleet-homelab/okta.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}
