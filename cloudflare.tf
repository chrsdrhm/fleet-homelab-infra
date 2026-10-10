# Delegates the Fleet subdomain to the Route 53 zone in dns.tf. The zone gets a
# new set of nameservers every time it is recreated, so these records are
# managed here instead of by hand. NS records cannot be proxied.
#
# Optional: with cloudflare_zone_name left empty (DNS hosted somewhere else), nothing
# here is created; add the four NS records from `terraform output fleet_name_servers`
# for fleet_subdomain at your DNS provider instead.
locals {
  use_cloudflare = var.cloudflare_zone_name != ""
}

data "cloudflare_zone" "parent" {
  count = local.use_cloudflare ? 1 : 0
  filter = {
    name = var.cloudflare_zone_name
  }
}

resource "cloudflare_dns_record" "fleet_ns" {
  count   = local.use_cloudflare ? 4 : 0
  zone_id = data.cloudflare_zone.parent[0].zone_id
  name    = var.fleet_subdomain
  type    = "NS"
  content = aws_route53_zone.fleet.name_servers[count.index]
  ttl     = 300
}
