# Delegates the Fleet subdomain to the Route 53 zone in dns.tf. The zone gets a
# new set of nameservers every time it is recreated, so these records are
# managed here instead of by hand. NS records cannot be proxied.
data "cloudflare_zone" "parent" {
  filter = {
    name = var.cloudflare_zone_name
  }
}

resource "cloudflare_dns_record" "fleet_ns" {
  count   = 4
  zone_id = data.cloudflare_zone.parent.zone_id
  name    = var.fleet_subdomain
  type    = "NS"
  content = aws_route53_zone.fleet.name_servers[count.index]
  ttl     = 300
}
