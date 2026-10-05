# Copy to backend.hcl (gitignored) and fill in your state bucket, then run:
#   terraform init -backend-config=backend.hcl
bucket = "fleet-homelab-tfstate-<aws-account-id>"
