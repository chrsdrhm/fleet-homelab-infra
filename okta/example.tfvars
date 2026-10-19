# Placeholders only, not real values. Copy to terraform.tfvars (gitignored) and fill
# in your own. example.com is reserved for documentation (RFC 2606).
fleet_subdomain       = "fleet.example.com"
okta_org_name         = "trial-0000000"
okta_client_id        = "0oaXXXXXXXXXXXXXXXXX"
okta_private_key_id   = "kid-from-the-service-apps-public-keys-table"
okta_private_key_path = "~/.okta/terraform.key"                     # a path to a file kept outside the repo, never the key
okta_app_logo_path    = "~/.config/fleet-homelab/okta-app-logo.png" # optional: the apps' icon, kept outside the repo
