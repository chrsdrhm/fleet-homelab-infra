# Lets GitHub Actions in this repo reach AWS without stored keys (Task 15). Two roles:
#  - apply: up/down/plan, only from a manually started run (workflow_dispatch) on main;
#  - plan:  read-only, only from pull_request runs (Task 16).
# Applied locally by an admin, never by CI: the apply role is denied from changing
# either role or policy, so a pending diff here makes a CI run fail with AccessDenied.
# GitHub issues the immutable subject format (repo:OWNER@ID/REPO@ID:...) for repos
# created after 2026-07-15, which this repo is.
data "tls_certificate" "github_actions" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

locals {
  account_id        = data.aws_caller_identity.current.account_id
  github_sub_prefix = "repo:${var.github_owner}@${var.github_owner_id}/fleet-homelab-infra@${var.github_repo_id}"
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_actions.certificates[0].sha1_fingerprint]
}

# ---------- Apply role: up / down / plan, workflow_dispatch on main only ----------

resource "aws_iam_role" "github_actions_apply" {
  name = "fleet-homelab-github-actions"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github_actions.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "${local.github_sub_prefix}:ref:refs/heads/main"
        }
      }
    }]
  })
}

data "aws_iam_policy_document" "github_actions_apply" {
  # Every AWS service the stack touches, derived from the resource types the
  # root module + addons actually create (not guessed): VPC/EC2, RDS, ElastiCache,
  # ECS + Application Auto Scaling (byo-ecs creates aws_appautoscaling_*), ELB,
  # WAFv2, CloudWatch (+ Logs), SES, Route 53, ACM, Firehose, Budgets.
  # No Lambda/Events/SNS: only the monitoring addon's unused cron_monitoring path
  # creates Lambda/Events, and no SNS topic is wired up.
  statement {
    sid    = "CoreInfraServices"
    effect = "Allow"
    actions = [
      "ec2:*", "rds:*", "elasticache:*", "ecs:*", "application-autoscaling:*",
      "elasticloadbalancing:*", "wafv2:*", "cloudwatch:*", "logs:*", "ses:*",
      "sesv2:*", "route53:*", "acm:*", "firehose:*", "budgets:*",
      "sts:GetCallerIdentity",
    ]
    resources = ["*"]
  }

  # Secrets Manager: every secret this stack creates is named fleet* (fleet-scep,
  # fleet-homelab/fleet-server-private-key, fleet-homelab-database-password).
  statement {
    sid       = "SecretsManagerFleetOnly"
    effect    = "Allow"
    actions   = ["secretsmanager:*"]
    resources = ["arn:aws:secretsmanager:*:${local.account_id}:secret:fleet*"]
  }

  statement {
    sid       = "SecretsManagerList"
    effect    = "Allow"
    actions   = ["secretsmanager:ListSecrets"]
    resources = ["*"]
  }

  # KMS: this deployment uses AWS-managed keys only (no CMKs), so no key
  # creation/policy-editing. Use of those keys is allowed only when a stack
  # service is the caller.
  statement {
    sid       = "KmsRead"
    effect    = "Allow"
    actions   = ["kms:Describe*", "kms:List*", "kms:Get*"]
    resources = ["*"]
  }

  statement {
    sid       = "KmsUseViaStackServices"
    effect    = "Allow"
    actions   = ["kms:CreateGrant", "kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey*", "kms:ReEncrypt*"]
    resources = ["*"]
    condition {
      test     = "StringLike"
      variable = "kms:ViaService"
      values = [
        "rds.*.amazonaws.com", "elasticache.*.amazonaws.com", "secretsmanager.*.amazonaws.com",
        "s3.*.amazonaws.com", "logs.*.amazonaws.com", "firehose.*.amazonaws.com",
        "ecs.*.amazonaws.com", "ec2.*.amazonaws.com", "ses.*.amazonaws.com",
      ]
    }
  }

  # S3: this project's own buckets (fleet-homelab-tfstate-*, -osquery-*, -audit) plus the
  # ECS module's software-installers bucket, which the module names itself with the
  # default prefix fleet-software-installers- (verified in byo-ecs variables.tf).
  statement {
    sid     = "ProjectS3Buckets"
    effect  = "Allow"
    actions = ["s3:*"]
    resources = [
      "arn:aws:s3:::fleet-homelab-*", "arn:aws:s3:::fleet-homelab-*/*",
      "arn:aws:s3:::fleet-software-installers-*", "arn:aws:s3:::fleet-software-installers-*/*",
    ]
  }

  # IAM read is account-wide (Terraform refresh needs it); IAM *write* is limited to
  # role/policy names the stack creates: fleet* (byo-ecs's fleet-role / fleet-execution-role,
  # this project's own names) and terraform-* (the AWS provider's auto-generated name for
  # resources with no explicit name — the Firehose roles and the SES/MDM policies have none,
  # verified in the addon source). Unlike a bare "*", this stops the role from touching any
  # existing role in the account (your SSO admin role, service roles) — e.g. rewriting its
  # trust policy and assuming it. If a first apply hits AccessDenied on an IAM ARN outside
  # these patterns, the error names it: widen this locally and re-apply.
  statement {
    sid       = "IamRead"
    effect    = "Allow"
    actions   = ["iam:Get*", "iam:List*"]
    resources = ["*"]
  }

  statement {
    sid    = "IamManageStackRolesAndPolicies"
    effect = "Allow"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:TagRole", "iam:UntagRole", "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy", "iam:PutRolePolicy", "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:CreatePolicy", "iam:DeletePolicy",
      "iam:CreatePolicyVersion", "iam:DeletePolicyVersion", "iam:TagPolicy", "iam:UntagPolicy",
    ]
    resources = [
      "arn:aws:iam::${local.account_id}:role/fleet*", "arn:aws:iam::${local.account_id}:role/terraform-*",
      "arn:aws:iam::${local.account_id}:policy/fleet*", "arn:aws:iam::${local.account_id}:policy/terraform-*",
    ]
  }

  # Roles may only be handed to the services that consume them here: ECS tasks
  # (task + execution roles), Firehose, RDS enhanced monitoring. Verify at execution:
  # a PassRole AccessDenied naming another service means add it here.
  statement {
    sid     = "PassStackRolesToStackServices"
    effect  = "Allow"
    actions = ["iam:PassRole"]
    resources = [
      "arn:aws:iam::${local.account_id}:role/fleet*", "arn:aws:iam::${local.account_id}:role/terraform-*",
    ]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com", "firehose.amazonaws.com", "monitoring.rds.amazonaws.com"]
    }
  }

  statement {
    sid       = "ServiceLinkedRoles"
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["arn:aws:iam::*:role/aws-service-role/*"]
  }

  # No IAM *user* write actions and no OIDC-provider write actions are granted at all:
  # Task 17's aws_iam_user/access key and the OIDC provider above are applied locally
  # by an admin; CI only refreshes them (read-only). A CI role that could PutUserPolicy
  # on a user it can also mint access keys for would be an admin-in-two-steps.

  # The role cannot change its own (or the plan role's) trust, policies, or boundary.
  statement {
    sid    = "DenyChangingCiRolesAndPolicies"
    effect = "Deny"
    actions = [
      "iam:UpdateAssumeRolePolicy", "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:AttachRolePolicy",
      "iam:DetachRolePolicy", "iam:UpdateRole", "iam:DeleteRole", "iam:TagRole", "iam:UntagRole",
      "iam:PutRolePermissionsBoundary", "iam:DeleteRolePermissionsBoundary",
      "iam:CreatePolicyVersion", "iam:DeletePolicyVersion", "iam:SetDefaultPolicyVersion",
      "iam:DeletePolicy", "iam:TagPolicy", "iam:UntagPolicy",
    ]
    resources = [
      "arn:aws:iam::${local.account_id}:role/fleet-homelab-github-actions*",
      "arn:aws:iam::${local.account_id}:policy/fleet-homelab-github-actions*",
    ]
  }

  # Belt and braces on top of the name scoping: no fully-broad managed policy on any role.
  statement {
    sid       = "DenyAttachingBroadManagedPolicies"
    effect    = "Deny"
    actions   = ["iam:AttachRolePolicy"]
    resources = ["*"]
    condition {
      test     = "ArnEquals"
      variable = "iam:PolicyARN"
      values = [
        "arn:aws:iam::aws:policy/AdministratorAccess",
        "arn:aws:iam::aws:policy/PowerUserAccess",
        "arn:aws:iam::aws:policy/IAMFullAccess",
      ]
    }
  }

  # The role authenticates via OIDC and never needs to assume anything. Same-account
  # trust policies that name this role's ARN would otherwise grant AssumeRole with no
  # identity-policy Allow at all, so a role it creates could hand it new powers.
  statement {
    sid       = "DenyAssumingOtherRoles"
    effect    = "Deny"
    actions   = ["sts:AssumeRole"]
    resources = ["*"]
  }

  # Fargate-only stack: nothing it manages launches a raw EC2 instance.
  statement {
    sid       = "DenyStandaloneComputeLaunch"
    effect    = "Deny"
    actions   = ["ec2:RunInstances"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "github_actions_apply" {
  name   = "fleet-homelab-github-actions"
  policy = data.aws_iam_policy_document.github_actions_apply.json
}

resource "aws_iam_role_policy_attachment" "github_actions_apply" {
  role       = aws_iam_role.github_actions_apply.name
  policy_arn = aws_iam_policy.github_actions_apply.arn
}

# ---------- Plan role: read-only, pull_request context only (Task 16) ----------

resource "aws_iam_role" "github_actions_plan" {
  name = "fleet-homelab-github-actions-plan"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github_actions.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "${local.github_sub_prefix}:pull_request"
        }
      }
    }]
  })
}

data "aws_iam_policy_document" "github_actions_plan" {
  # Describe/List/Get only, for the services the state tracks. Deliberately not the
  # AWS-managed ReadOnlyAccess policy, which would also allow reading the contents
  # of every S3 bucket in the account. A plan that hits AccessDenied on a read call
  # names it: add it here (locally).
  statement {
    sid    = "ReadStackServices"
    effect = "Allow"
    actions = [
      "ec2:Describe*", "rds:Describe*", "rds:List*", "elasticache:Describe*", "elasticache:List*",
      "ecs:Describe*", "ecs:List*", "application-autoscaling:Describe*", "application-autoscaling:List*",
      "elasticloadbalancing:Describe*", "wafv2:Get*", "wafv2:List*", "wafv2:Describe*",
      "cloudwatch:Describe*", "cloudwatch:Get*", "cloudwatch:List*", "logs:Describe*", "logs:ListTagsForResource",
      "ses:Get*", "ses:List*", "ses:Describe*", "sesv2:Get*", "sesv2:List*", "route53:Get*", "route53:List*",
      "acm:Describe*", "acm:List*", "firehose:Describe*", "firehose:List*", "budgets:ViewBudget", "budgets:ListTagsForResource",
      "iam:Get*", "iam:List*", "kms:Describe*", "kms:List*", "kms:Get*", "sts:GetCallerIdentity", "tag:GetResources",
    ]
    resources = ["*"]
  }

  # Terraform's refresh reads secret_version resources (the private key, the Aurora
  # password) — unavoidable for a real plan, and the state file it reads holds the same
  # values in plaintext anyway. Scoped to fleet* secrets only.
  statement {
    sid       = "ReadFleetSecrets"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret", "secretsmanager:GetResourcePolicy", "secretsmanager:ListSecrets"]
    resources = ["*"]
    condition {
      test     = "StringLike"
      variable = "secretsmanager:SecretId"
      values   = ["arn:aws:secretsmanager:*:${local.account_id}:secret:fleet*"]
    }
  }

  # Bucket-level reads on project buckets (config only), object reads on the state bucket only —
  # not the osquery/audit log buckets' contents. The plan runs with -lock=false (Task 16), so
  # it needs no S3 write at all.
  statement {
    sid       = "ReadProjectBucketConfig"
    effect    = "Allow"
    actions   = ["s3:Get*", "s3:List*"]
    resources = ["arn:aws:s3:::fleet-homelab-*", "arn:aws:s3:::fleet-software-installers-*"]
  }

  statement {
    sid       = "ReadTerraformState"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::fleet-homelab-tfstate-*/*"]
  }
}

resource "aws_iam_policy" "github_actions_plan" {
  name   = "fleet-homelab-github-actions-plan"
  policy = data.aws_iam_policy_document.github_actions_plan.json
}

resource "aws_iam_role_policy_attachment" "github_actions_plan" {
  role       = aws_iam_role.github_actions_plan.name
  policy_arn = aws_iam_policy.github_actions_plan.arn
}

output "github_actions_apply_role_arn" {
  value = aws_iam_role.github_actions_apply.arn
}

output "github_actions_plan_role_arn" {
  value = aws_iam_role.github_actions_plan.arn
}
