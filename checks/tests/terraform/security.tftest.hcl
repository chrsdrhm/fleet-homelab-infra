# Pins down settings that would be dangerous to change by accident: who can assume the
# CI roles, the WAF's rule order, what the public logo bucket exposes, and the budget.
# Runs a plan against mocked providers: no AWS, Cloudflare or credentials needed, so it
# runs in the lint job for every pull request. Run locally with: terraform test
#
# The policy JSON from aws_iam_policy_document is mocked, so the tests check the
# statements as written in oidc.tf, not AWS's rendering of them. prevent_destroy is
# not visible to tests; the plan check's data-loss guard covers those resources.
#
# Every value in this file is a placeholder, not real data: 123456789012 is the example
# account ID from AWS's documentation, example.com is reserved for documentation
# (RFC 2606), "octo"/1/2 are made-up GitHub IDs, and the keys and tokens are dummies.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1", name = "us-east-1" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws", dns_suffix = "amazonaws.com" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}
mock_provider "cloudflare" {}
mock_provider "tls" {
  mock_data "tls_certificate" {
    defaults = { certificates = [{ sha1_fingerprint = "0000000000000000000000000000000000000000" }] }
  }
}
mock_provider "random" {}
mock_provider "null" {}

# Values the plan needs before apply (a mocked plan leaves them unknown otherwise).
override_resource {
  target          = aws_acm_certificate.fleet
  override_during = plan
  values = {
    arn = "arn:aws:acm:us-east-1:123456789012:certificate/test"
    domain_validation_options = [{
      domain_name           = "fleet.example.com"
      resource_record_name  = "_test.fleet.example.com."
      resource_record_value = "_test.acm-validations.aws."
      resource_record_type  = "CNAME"
    }]
  }
}

override_resource {
  target          = aws_secretsmanager_secret.fleet_server_private_key
  override_during = plan
  values = {
    arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:fleet-homelab/fleet-server-private-key-abc123"
  }
}

override_resource {
  target          = aws_iam_openid_connect_provider.github_actions
  override_during = plan
  values = {
    arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  }
}

override_resource {
  target          = aws_s3_bucket.idp_logo
  override_during = plan
  values = {
    arn = "arn:aws:s3:::fleet-homelab-idp-logo-123456789012"
  }
}

variables {
  fleet_subdomain      = "fleet.example.com"
  fleet_license_key    = "test"
  cloudflare_api_token = "test"
  cloudflare_zone_name = "example.com"
  budget_alert_email   = "budget@example.com"
  waf_ci_header_value  = "0123456789abcdef0123456789abcdef"
  github_owner         = "octo"
  github_owner_id      = "1"
  github_repo_id       = "2"
}

run "ci_roles_trust_only_their_own_triggers" {
  command = plan

  assert {
    condition     = length(jsondecode(aws_iam_role.github_actions_apply.assume_role_policy).Statement) == 1
    error_message = "The apply role's trust policy must have exactly one statement."
  }
  assert {
    condition = jsondecode(aws_iam_role.github_actions_apply.assume_role_policy).Statement[0].Condition.StringEquals == {
      "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
      "token.actions.githubusercontent.com:sub" = "repo:octo@1/fleet-homelab-infra@2:ref:refs/heads/main"
    }
    error_message = "The apply role must trust only a run on main in this repo (exact sub, StringEquals)."
  }
  assert {
    condition     = length(jsondecode(aws_iam_role.github_actions_plan.assume_role_policy).Statement) == 1
    error_message = "The plan role's trust policy must have exactly one statement."
  }
  assert {
    condition = jsondecode(aws_iam_role.github_actions_plan.assume_role_policy).Statement[0].Condition.StringEquals == {
      "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
      "token.actions.githubusercontent.com:sub" = "repo:octo@1/fleet-homelab-infra@2:pull_request"
    }
    error_message = "The plan role must trust only pull_request runs in this repo (exact sub, StringEquals)."
  }
  assert {
    condition     = length(jsondecode(aws_iam_role.github_actions_scan.assume_role_policy).Statement) == 1
    error_message = "The scan role's trust policy must have exactly one statement."
  }
  assert {
    condition = jsondecode(aws_iam_role.github_actions_scan.assume_role_policy).Statement[0].Condition.StringEquals == {
      "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
      "token.actions.githubusercontent.com:sub" = "repo:octo@1/fleet-homelab-infra@2:ref:refs/heads/main"
    }
    error_message = "The scan role must trust only a run on main in this repo (exact sub, StringEquals)."
  }
}

run "apply_role_keeps_its_denies" {
  command = plan

  assert {
    condition = alltrue([
      for sid in ["DenyChangingCiRolesAndPolicies", "DenyAttachingBroadManagedPolicies", "DenyAssumingOtherRoles", "DenyStandaloneComputeLaunch"] :
      contains([for s in data.aws_iam_policy_document.github_actions_apply.statement : s.sid if s.effect == "Deny"], sid)
    ])
    error_message = "The apply role's policy must keep all four Deny statements."
  }
}

run "plan_role_is_read_only" {
  command = plan

  assert {
    condition = alltrue(flatten([
      for s in data.aws_iam_policy_document.github_actions_plan.statement : [
        for a in s.actions : can(regex("^[a-z0-9-]+:(Describe|Get|List|View)", a))
      ] if s.effect == "Allow"
    ]))
    error_message = "Every action the plan role allows must be a Describe, Get, List or View action."
  }
}

run "scan_role_is_read_only" {
  command = plan

  assert {
    condition = alltrue(flatten([
      for s in data.aws_iam_policy_document.github_actions_scan.statement : [
        for a in s.actions : can(regex("^[a-z0-9-]+:(Describe|Get|List|View)", a)) || a == "logs:StartQuery"
      ] if s.effect == "Allow"
    ]))
    error_message = "Every action the scan role allows must be a Describe, Get, List or View action, or logs:StartQuery."
  }
  assert {
    condition     = one([for s in data.aws_iam_policy_document.github_actions_scan.statement : s.resources if contains(s.actions, "logs:StartQuery")]) == toset(["arn:aws:logs:*:123456789012:log-group:terraform-*"])
    error_message = "The scan role may start Logs Insights queries only on Fleet's log group (terraform-*)."
  }
}

run "waf_blocks_by_default_and_checks_the_ci_header_first" {
  command = plan

  assert {
    condition     = length(aws_wafv2_web_acl.fleet_homelab.default_action[0].block) == 1
    error_message = "The WAF must block by default."
  }
  assert {
    condition     = [for r in aws_wafv2_web_acl.fleet_homelab.rule : r.priority if r.name == "allow-ci-header"] == [0]
    error_message = "allow-ci-header must exist at priority 0."
  }
  assert {
    condition     = [for r in aws_wafv2_web_acl.fleet_homelab.rule : r.priority if r.name == "allow-us"] == [1]
    error_message = "allow-us must exist at priority 1."
  }
  assert {
    condition     = [for r in aws_wafv2_web_acl.fleet_homelab.rule : r.visibility_config[0].sampled_requests_enabled if r.name == "allow-ci-header"] == [false]
    error_message = "allow-ci-header must not sample requests (samples would record the header value)."
  }
  assert {
    # The rule set holds the (sensitive) CI header value, so unwrap just the country list.
    condition     = nonsensitive(flatten([for r in aws_wafv2_web_acl.fleet_homelab.rule : r.statement[0].geo_match_statement[0].country_codes if r.name == "allow-us"])) == ["US"]
    error_message = "allow-us must allow the US only."
  }
}

run "logo_bucket_exposes_one_object_read_only" {
  command = plan

  assert {
    condition = jsondecode(aws_s3_bucket_policy.idp_logo.policy).Statement == [{
      Sid       = "PublicReadLogoOnly"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "arn:aws:s3:::fleet-homelab-idp-logo-123456789012/idp-logo.png"
    }]
    error_message = "The logo bucket policy must allow only public GetObject on idp-logo.png."
  }
  assert {
    condition     = aws_s3_bucket_public_access_block.idp_logo.block_public_acls && aws_s3_bucket_public_access_block.idp_logo.ignore_public_acls
    error_message = "The logo bucket must not allow public ACLs."
  }
  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.software_installers.block_public_acls,
      aws_s3_bucket_public_access_block.software_installers.block_public_policy,
      aws_s3_bucket_public_access_block.software_installers.ignore_public_acls,
      aws_s3_bucket_public_access_block.software_installers.restrict_public_buckets,
    ])
    error_message = "The software-installers bucket must block all public access."
  }
}

run "budget_alerts_every_ten_dollars" {
  command = plan

  assert {
    condition     = toset([for n in aws_budgets_budget.fleet_homelab.notification : tonumber(n.threshold)]) == toset([10, 20, 30, 40, 50, 60, 70, 80, 90, 100])
    error_message = "The budget must alert at every $10 from $10 to $100."
  }
}

run "dns_delegation_uses_cloudflare_only_when_configured" {
  command = plan

  assert {
    condition     = length(cloudflare_dns_record.fleet_ns) == 4
    error_message = "With a Cloudflare zone set, the four NS records delegating the subdomain must be created."
  }
}

run "dns_elsewhere_skips_cloudflare" {
  command = plan

  variables {
    cloudflare_zone_name = ""
    cloudflare_api_token = ""
  }

  assert {
    condition     = length(cloudflare_dns_record.fleet_ns) == 0 && length(data.cloudflare_zone.parent) == 0
    error_message = "With no Cloudflare zone, nothing in Cloudflare may be read or created (the NS records are added by hand)."
  }
}
