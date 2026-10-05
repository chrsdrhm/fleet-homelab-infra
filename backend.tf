terraform {
  backend "s3" {
    # `bucket` is deliberately NOT here: its name embeds the AWS account ID, which is kept
    # out of this public repo. Supply it at init time from the gitignored backend.hcl:
    #   terraform init -backend-config=backend.hcl      (see backend.example.hcl)
    key          = "fleet-homelab/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}
