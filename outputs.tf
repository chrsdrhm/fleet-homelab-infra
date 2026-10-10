output "fleet_url" {
  value = "https://${var.fleet_subdomain}"
}

# The four name servers that fleet_subdomain must be delegated to (NS records at the
# parent domain's DNS provider). cloudflare.tf adds them when DNS is on Cloudflare.
output "fleet_name_servers" {
  value = aws_route53_zone.fleet.name_servers
}
