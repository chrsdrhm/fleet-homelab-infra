terraform {
  backend "s3" {
    bucket       = "fleet-homelab-tfstate-550510536085"
    key          = "fleet-homelab/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}
