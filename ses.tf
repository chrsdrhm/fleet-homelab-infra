module "ses" {
  source = "github.com/fleetdm/fleet-terraform//addons/ses?depth=1&ref=tf-mod-addon-ses-v1.5.0"

  domain  = var.fleet_subdomain
  zone_id = aws_route53_zone.fleet.zone_id
}
