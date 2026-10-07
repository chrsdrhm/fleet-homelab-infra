# Not Fleet's own waf-alb addon: that addon can only express "block these
# specific countries/IPs, default-allow everything else" or "allow these
# specific IPs, default-block everything else" (verified against its
# variables.tf/main.tf) — there is no "allow only this one country" mode.
# A blocklist covering every non-US country also hit a real AWS limit:
# geo_match_statement.country_codes allows at most 50 entries (confirmed by
# a failed apply), so the addon's single-statement design can't express this
# at all, and a maintained "block everyone except US" list would silently
# admit any country AWS adds in the future until updated. Allow-only-US with
# a default block is simpler, fits in one country code, and needs no upkeep.
resource "aws_wafv2_web_acl" "fleet_homelab" {
  name        = "fleet-homelab"
  description = "Allow US traffic and the CI header, block everything else by default"
  scope       = "REGIONAL"

  default_action {
    block {}
  }

  # GitHub-hosted runners run in Azure regions worldwide, so the GitOps workflow is
  # often outside the US and would be blocked by the rule below. It sends a secret
  # header instead (fleetctl --custom-header); this rule lets only those requests
  # skip the country check. Fleet still requires an API token on every call.
  # Sampled requests are off, since samples would record the header value.
  rule {
    name     = "allow-ci-header"
    priority = 0

    action {
      allow {}
    }

    statement {
      byte_match_statement {
        search_string         = var.waf_ci_header_value
        positional_constraint = "EXACTLY"

        field_to_match {
          single_header {
            name = "x-fleet-ci"
          }
        }

        text_transformation {
          priority = 0
          type     = "NONE"
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "fleet-homelab-allow-ci-header"
      sampled_requests_enabled   = false
    }
  }

  rule {
    name     = "allow-us"
    priority = 1

    action {
      allow {}
    }

    statement {
      geo_match_statement {
        country_codes = ["US"]
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "fleet-homelab-allow-us"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "fleet-homelab"
    sampled_requests_enabled   = true
  }
}

resource "aws_wafv2_web_acl_association" "fleet_homelab" {
  resource_arn = module.fleet.byo-vpc.byo-db.alb.arn
  web_acl_arn  = aws_wafv2_web_acl.fleet_homelab.arn
}
