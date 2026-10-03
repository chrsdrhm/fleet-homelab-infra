# Same state bucket as the AWS stack, separate key: Entra changes and AWS
# changes never share a state file or a lock.
terraform {
  backend "s3" {
    bucket       = "fleet-homelab-tfstate-<aws-account-id>"
    key          = "fleet-homelab/entra.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}
