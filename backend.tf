terraform {
  backend "s3" {
    bucket       = "fleet-homelab-tfstate-<aws-account-id>"
    key          = "fleet-homelab/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}
