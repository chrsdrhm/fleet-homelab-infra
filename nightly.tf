# Starts the nightly check at 3am Chicago time from AWS (plan Task 37). GitHub's own
# schedule often started hours late, past the 7:59am cutoff, so a stack left up stayed up
# all day; EventBridge Scheduler fires on time and follows daylight saving. 3am, not 2am:
# on the night clocks spring forward, 2:00-2:59 doesn't exist and Scheduler skips the
# run. It calls a small Lambda function (lambda/nightly/index.mjs) that dispatches
# terraform.yml with action=nightly, signing in as a GitHub App whose client ID and key
# are SSM parameters set by hand (docs/github-setup.md). The workflow treats any run the
# app starts as the nightly check, so the app can't start an up or a down.
#
# Kept through teardowns: down.sh doesn't target any of this, since it has to fire while
# the stack is up. A failed or missed start emails budget_alert_email (confirm the
# subscription once).

locals {
  nightly_name                = "fleet-homelab-nightly"
  nightly_client_id_parameter = "/fleet-homelab/nightly-app/client-id"
  nightly_key_parameter       = "/fleet-homelab/nightly-app/private-key"
}

data "archive_file" "nightly" {
  type        = "zip"
  source_file = "${path.module}/lambda/nightly/index.mjs"
  output_path = "${path.module}/.terraform/nightly.zip"
}

resource "aws_cloudwatch_log_group" "nightly" {
  name              = "/aws/lambda/${local.nightly_name}"
  retention_in_days = 30
}

data "aws_iam_policy_document" "nightly_function_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "nightly_function" {
  name               = "${local.nightly_name}-function"
  assume_role_policy = data.aws_iam_policy_document.nightly_function_trust.json
}

# Only the two parameters, and its own logs.
data "aws_iam_policy_document" "nightly_function" {
  statement {
    sid     = "ReadAppParameters"
    actions = ["ssm:GetParameter"]
    resources = [
      "arn:aws:ssm:${data.aws_region.current.region}:${local.account_id}:parameter${local.nightly_client_id_parameter}",
      "arn:aws:ssm:${data.aws_region.current.region}:${local.account_id}:parameter${local.nightly_key_parameter}",
    ]
  }

  # The key is a SecureString under the AWS managed aws/ssm key, decrypted through SSM.
  statement {
    sid       = "DecryptViaSsm"
    actions   = ["kms:Decrypt"]
    resources = ["arn:aws:kms:${data.aws_region.current.region}:${local.account_id}:key/*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${data.aws_region.current.region}.amazonaws.com"]
    }
  }

  statement {
    sid       = "WriteOwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.nightly.arn}:*"]
  }
}

resource "aws_iam_role_policy" "nightly_function" {
  name   = "${local.nightly_name}-function"
  role   = aws_iam_role.nightly_function.id
  policy = data.aws_iam_policy_document.nightly_function.json
}

resource "aws_lambda_function" "nightly" {
  function_name    = local.nightly_name
  description      = "Starts the nightly check (terraform.yml, action=nightly)"
  role             = aws_iam_role.nightly_function.arn
  runtime          = "nodejs24.x"
  architectures    = ["arm64"]
  handler          = "index.handler"
  filename         = data.archive_file.nightly.output_path
  source_code_hash = data.archive_file.nightly.output_base64sha256
  memory_size      = 256
  timeout          = 30

  environment {
    variables = {
      REPO                = "${var.github_owner}/fleet-homelab-infra"
      CLIENT_ID_PARAMETER = local.nightly_client_id_parameter
      KEY_PARAMETER       = local.nightly_key_parameter
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.nightly.name
  }

  depends_on = [aws_iam_role_policy.nightly_function]
}

data "aws_iam_policy_document" "nightly_scheduler_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "nightly_scheduler" {
  name               = "${local.nightly_name}-scheduler"
  assume_role_policy = data.aws_iam_policy_document.nightly_scheduler_trust.json
}

data "aws_iam_policy_document" "nightly_scheduler" {
  statement {
    sid       = "InvokeNightlyFunction"
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.nightly.arn]
  }
}

resource "aws_iam_role_policy" "nightly_scheduler" {
  name   = "${local.nightly_name}-scheduler"
  role   = aws_iam_role.nightly_scheduler.id
  policy = data.aws_iam_policy_document.nightly_scheduler.json
}

resource "aws_scheduler_schedule" "nightly" {
  name                         = local.nightly_name
  description                  = "The nightly check, 3am Chicago time all year"
  schedule_expression          = "cron(0 3 * * ? *)"
  schedule_expression_timezone = "America/Chicago"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.nightly.arn
    role_arn = aws_iam_role.nightly_scheduler.arn

    retry_policy {
      maximum_event_age_in_seconds = 3600
      maximum_retry_attempts       = 2
    }
  }
}

# A failed or missed start is emailed: the function erroring (a bad key, GitHub down), or
# not being called at all (the scheduler gave up, or the schedule is disabled or gone).
resource "aws_sns_topic" "nightly_alerts" {
  name = "${local.nightly_name}-alerts"
}

resource "aws_sns_topic_subscription" "nightly_alerts" {
  topic_arn = aws_sns_topic.nightly_alerts.arn
  protocol  = "email"
  endpoint  = var.budget_alert_email
}

resource "aws_cloudwatch_metric_alarm" "nightly_function_errors" {
  alarm_name          = "${local.nightly_name}-function-errors"
  alarm_description   = "The nightly timer's function failed to start the nightly check. See its log group, /aws/lambda/${local.nightly_name}."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.nightly.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.nightly_alerts.arn]
}

# No call in 26 hours: one run's gap is 23 to 25 hours around daylight saving changes,
# so a missed 3am run alarms around 5am. No data counts as missing a run.
resource "aws_cloudwatch_metric_alarm" "nightly_missed" {
  alarm_name          = "${local.nightly_name}-missed"
  alarm_description   = "The nightly timer's function wasn't called in the last 26 hours, so the nightly check didn't start. Check the schedule, ${local.nightly_name}, in EventBridge Scheduler."
  namespace           = "AWS/Lambda"
  metric_name         = "Invocations"
  dimensions          = { FunctionName = aws_lambda_function.nightly.function_name }
  statistic           = "Sum"
  period              = 3600
  evaluation_periods  = 26
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.nightly_alerts.arn]
}
