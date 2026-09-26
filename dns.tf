resource "aws_route53_zone" "fleet" {
  name = var.fleet_subdomain
}

resource "aws_acm_certificate" "fleet" {
  domain_name       = var.fleet_subdomain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "fleet_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.fleet.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id = aws_route53_zone.fleet.zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
}

resource "aws_acm_certificate_validation" "fleet" {
  certificate_arn         = aws_acm_certificate.fleet.arn
  validation_record_fqdns = [for r in aws_route53_record.fleet_cert_validation : r.fqdn]
}
