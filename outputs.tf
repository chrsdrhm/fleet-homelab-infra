output "fleet_url" {
  value = "https://${var.fleet_subdomain}"
  # The hostname; `terraform output -raw fleet_url` (up.sh, health-scan.sh) still shows it.
  sensitive = true
}

# The four name servers that fleet_subdomain must be delegated to (NS records at the
# parent domain's DNS provider). cloudflare.tf adds them when DNS is on Cloudflare.
output "fleet_name_servers" {
  value = aws_route53_zone.fleet.name_servers
  # Sensitive: the set of four is close to unique, so it can lead back to the domain.
  # Hidden in plans and CI logs; `terraform output fleet_name_servers` still shows it.
  sensitive = true
}
