# Fleet Homelab on AWS Implementation Plan

> Implementation plan. Steps use checkbox (`- [ ]`) syntax for tracking progress.

**Goal:** Stand up a publicly-accessible, Okta-SSO-federated, GitOps-managed Fleet Premium instance in my AWS account (`us-east-1`), matching Fleet's own recommended reference architecture as closely as possible, run intermittently (evenings/weekends) via full teardown/rebuild rather than continuously.

**Architecture:** Terraform calls Fleet's own **root module** directly — one module call provisions the VPC, Aurora MySQL, Redis, an ALB, and an ECS Fargate service together, wiring their connection info and security groups automatically. This is a change from an earlier draft of this plan that called the nested `byo-vpc` module and hand-wrote a separate VPC — that split only existed to support NAT-off/public-subnet Fargate, a configuration this plan no longer uses (NAT is on, Fargate is private, which is the root module's own hardcoded default). Using the root module directly is simpler and closer to Fleet's own reference example. WAF, monitoring, SES, MDM, and Firehose log delivery are added as Fleet's own addon modules. A separate `fleetctl new`-scaffolded repo drives Fleet's application config (SSO, teams, policies) via GitHub Actions GitOps. `up`/`down` scripts fully tear down and rebuild the stack each session, preserving actual Fleet data (not just infrastructure) via an Aurora snapshot and an externalized encryption key. The infra repo itself closes its own GitOps loop too (Tasks 15–16): `up`/`down`/`plan` run via a GitHub Actions workflow assuming an AWS role through OIDC (no long-lived keys in GitHub), triggered on demand rather than on push, and every `.tf` change gets a `terraform plan` posted to its PR before merge — git is the source of truth for infra the same way it is for Fleet's own config, without forcing an apply every time something merges. A Grafana instance on Proxmox (Task 17) rounds this out with a dashboard over both CloudWatch infra metrics and Fleet's own asset data (hosts, policy compliance, vulnerabilities) — the one place a long-lived AWS credential exists in this whole plan, since Grafana runs outside AWS with no OIDC-equivalent federation path available to it.

**Tech Stack:** Terraform >= 1.12.0, AWS provider >= 6.37.0, `fleetdm/fleet-terraform` (root module + addons), `fleetctl`, GitHub Actions (OIDC-federated, no stored AWS credentials).

**Spec:** `docs/superpowers/specs/2026-09-17-fleet-homelab-aws-design.md`

**Status as of 2026-10-05** (checkboxes reconciled against git history, Terraform state and live AWS; steps that cannot be verified from here stay open):
- **Built and verified:** Tasks 1, 2, 3 (except Step 8b), 4, 6, 7, 8 Part A (Windows MDM certificate), 9, 10 (Okta SSO), 11 (GitOps repo), and 13 (budget; Step 5, checking the inbox, is open).
- **Open:** Task 3 Step 8b (read-only `fleetctl` tour), Task 8 Part B (Apple push certificate; optional), Task 11 Step 9 (its Apple half), Task 12 (osquery logs, not started), Tasks 14 (scripts), 15 (CI/OIDC), 16 (PR plan checks), 17 (Grafana plus alerting), 19 (activities webhook, written, not built), 20 (end-user SSO; Okta steps still to be derived).
- **Superseded or retired:** Task 5 (folded into Task 17), Task 18 (retired with Entra).
- **Running state:** the stack is torn down and rebuilt by hand with the snapshot pattern in Task 14's notes (no scripts yet), and `okta/` is applied locally.


## Global Constraints

- **`fleetctl` is hands-on: I run every `fleetctl` command myself, to learn the tool.** Each step explains what the command does and what output to expect. Steps marked **🎓 You run this** follow this rule; commands that prompt for a password or print a one-time token have to be run by hand regardless. **Installing `fleetctl` is a prerequisite that is deliberately not done up front (Task 3 Step 8a; needed no later than Task 8 Step 5 or Task 11 Step 1): before any `fleetctl` step, check `which fleetctl && fleetctl --version` and stop if it's missing or not 4.92.0.**

- Region: `us-east-1`.
- NAT Gateway present (single gateway, module default). Fargate task in a **private** subnet with egress via NAT; Aurora and Redis stay in database/elasticache subnets with no internet route regardless.
- Database: **Aurora MySQL**, `db.t4g.medium`, `replicas = 1` — in `byo-vpc` this is the **total instance count** (`if index < config.replicas`), so `1` = one writer instance and no reader; `0` would create a cluster with **no instances at all** (verified against the module source; an earlier draft had `0`). Instance identifier is `fleet-homelab-one`, cluster identifier `fleet-homelab`.
- Redis: `cache.t4g.small`, `cluster_size = 1`, no automatic failover.
- Fargate: `cpu = 512`, `mem = 4096` (vulnerability scanning stays on — my explicit choice).
- **No read replicas, no Redis failover, `autoscaling.min_capacity = 1`** — deliberately skipped regardless of cost, since my priority is "if it breaks, I rebuild it," not uptime during an incident. This is a separate axis from the Aurora/Redis-size decisions above.
- **Only override module defaults where this deployment genuinely needs something different.** An earlier draft of this plan re-specified the module's own default CIDR ranges, AZ layout, and NAT settings verbatim — pure noise. Match Fleet's own example's minimalism: set `name`/`azs` on `vpc`, leave everything else alone unless there's a specific reason not to.
- AWS-managed KMS keys everywhere (no CMKs) — simplest, avoids extra KMS cost.
- Fleet module refs are pinned exactly as listed per task — do not float to `main`/latest.
- Every secret value this stack creates (Aurora password, Fleet server private key, the Windows MDM WSTEP pair) lives in AWS Secrets Manager, **except** the break-glass Fleet admin password, which goes in my personal password manager, never in AWS. Apple MDM's APNs key and SCEP CA are generated and kept by the Fleet server itself (in the database), not in AWS secrets.
- Terraform state: S3 backend with native locking (`use_lockfile = true` — no DynamoDB table; `dynamodb_table` was deprecated in Terraform 1.11), created once in Task 1 and never destroyed by the `down` script.
- **Teardown must preserve state, not just be cheap**: the `down` script snapshots Aurora before destroying it, and the Fleet server's encryption key, the software-installers bucket, and the MDM secrets are excluded from teardown entirely — see Task 14.
- **No personal or account-identifying information in either public repo: not in files, not in commit messages, not in history.** That covers the Fleet hostname and domain, the AWS account ID and anything derived from it (state bucket name, role ARNs, the logo bucket URL), Okta org names, IDs and URLs, tenant IDs, personal email addresses, and every credential. Real values live in gitignored files (`terraform.tfvars`, `backend.hcl`) or GitHub Actions secrets; the repos contain placeholders such as `<fleet-hostname>`, `<aws-account-id>` and `<your-domain>`. **Before every push, and whenever this rule changes, scan the tracked files, every commit message and the full history** (`git grep` over `git rev-list --all`, `git log --all --grep`, `git log -S`), and prefer a fresh clone as the test. Run any command that prints a secret in a separate terminal, not with the `!` prefix.

---

### Task 1: Terraform state backend + provider bootstrap

**The state bucket name is not in the repo.** `backend.tf` (and `okta/backend.tf`) hold a partial `s3` backend configuration, and the bucket name comes from a gitignored `backend.hcl` (template: `backend.example.hcl`) at init time: `terraform init -backend-config=backend.hcl` (add `-reconfigure` after changing it). A backend block cannot read variables, so tfvars cannot supply it. See Global Constraints for why, and Task 15 for the CI consequence (the bucket comes from a repository secret).

**Files:**
- Create: `providers.tf`
- Create: `backend.tf`
- Create: `.gitignore`

**Interfaces:**
- Produces: an S3 bucket every later task's `terraform init` depends on.

- [x] **Step 1: Create the state bucket via AWS CLI**

No DynamoDB lock table — `dynamodb_table` was deprecated in Terraform 1.11 (late 2024) in favor of S3's own native conditional-write locking (`use_lockfile = true` on the backend, Step 4). Caught and fixed during execution, not planned this way from the start — worth naming since "S3 + DynamoDB for state locking" is still what most Terraform tutorials show.

```bash
aws s3api create-bucket \
  --bucket fleet-homelab-tfstate-$(aws sts get-caller-identity --query Account --output text) \
  --region us-east-1

aws s3api put-bucket-versioning \
  --bucket fleet-homelab-tfstate-$(aws sts get-caller-identity --query Account --output text) \
  --versioning-configuration Status=Enabled

aws s3api put-public-access-block \
  --bucket fleet-homelab-tfstate-$(aws sts get-caller-identity --query Account --output text) \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# The provider's default_tags can't reach this bucket (it exists before Terraform does),
# so it carries the same tags by hand. Everything else in this project is tagged
# automatically; anything ever created via the CLI must be tagged like this.
aws s3api put-bucket-tagging \
  --bucket fleet-homelab-tfstate-$(aws sts get-caller-identity --query Account --output text) \
  --tagging 'TagSet=[{Key=Project,Value=fleet-lab},{Key=ManagedBy,Value=terraform}]'
```

- [x] **Step 2: Verify it exists**

Run: `aws s3api head-bucket --bucket fleet-homelab-tfstate-$(aws sts get-caller-identity --query Account --output text)`
Expected: no error.

- [x] **Step 3: Write `providers.tf`**

```hcl
terraform {
  required_version = ">= 1.12.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.37.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"

  # Applied to every taggable resource, including those inside the Fleet
  # modules. Find everything with: Tag Editor / Resource Groups on Project=fleet-lab.
  default_tags {
    tags = {
      Project   = "fleet-lab"
      ManagedBy = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}
```

- [x] **Step 4: Write `backend.tf`** (substitute the real account ID printed by Step 2)

```hcl
terraform {
  backend "s3" {
    bucket       = "fleet-homelab-tfstate-<ACCOUNT_ID>"
    key          = "fleet-homelab/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}
```

- [x] **Step 5: Write `.gitignore`**

```
.terraform/
*.tfstate
*.tfstate.*
*.tfvars
!example.tfvars
crash.log
```

- [x] **Step 6: Init and verify**

Run: `terraform init`
Expected: `Successfully configured the backend "s3"!` and `Terraform has been successfully initialized!`

- [x] **Step 7: Commit**

```bash
git add providers.tf backend.tf .gitignore .terraform.lock.hcl
git commit -m "Bootstrap Terraform S3 state backend (native locking)"
```

Includes `.terraform.lock.hcl` — Terraform generates and explicitly recommends committing it on first `init`, to pin provider versions for reproducibility.

---

### Task 2: Route 53 hosted zone + ACM certificate

**Files:**
- Create: `dns.tf`
- Create: `variables.tf`
- Create: `terraform.tfvars` (not committed — in `.gitignore`)
- Create: `example.tfvars`

**Interfaces:**
- Consumes: nothing.
- Produces: `aws_acm_certificate_validation.fleet.certificate_arn`, `aws_route53_zone.fleet.zone_id` — consumed by Task 3 (ALB) and Task 6 (SES).

- [x] **Step 1: Write `variables.tf`**

```hcl
variable "fleet_subdomain" {
  description = "Fully-qualified domain name Fleet will be served on, e.g. fleet.example.com"
  type        = string
}

variable "fleet_license_key" {
  description = "Fleet Premium license key"
  type        = string
  sensitive   = true
}

variable "rds_snapshot_identifier" {
  description = "Aurora cluster snapshot to restore from on apply. Leave null for a fresh empty database (first-ever apply); set it to restore state after a teardown (see scripts/up.sh)."
  type        = string
  default     = null
}
```

- [x] **Step 2: Write `example.tfvars`**

```hcl
fleet_subdomain   = "fleet.example.com"
fleet_license_key = "replace-with-real-license-key"
```

- [x] **Step 3: Write `terraform.tfvars`** with your real subdomain and license key (not shown here — real values, gitignored).

- [x] **Step 4: Write `dns.tf`**

```hcl
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
```

- [x] **Step 5: Apply and get the NS records**

Run: `terraform apply -var-file=terraform.tfvars -target=aws_route53_zone.fleet`
Then: `aws route53 get-hosted-zone --id $(terraform state show aws_route53_zone.fleet | grep -m1 'zone_id ' | awk '{print $3}' | tr -d '"') --query 'DelegationSet.NameServers'`
Expected: 4 NS hostnames printed.

- [x] **Step 6: Delegate the subdomain in Cloudflare — automated (`cloudflare.tf`)**

The zone gets a *new* set of four nameservers every time it is recreated, so the delegation is managed in code instead of by hand. Verified against `cloudflare/cloudflare` v5.26.0's schema: `cloudflare_dns_record` requires `zone_id`, `name`, `type`, `ttl` (plus `content`), and `data "cloudflare_zone"` looks a zone up by `filter = { name = ... }`.

Add to `providers.tf`:

```hcl
# in required_providers:
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }

# Token scope: Zone > DNS > Edit, on the one zone only.
provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
```

Add to `variables.tf` (and `example.tfvars`): `cloudflare_api_token` (string, sensitive) and `cloudflare_zone_name` (string, the apex zone, e.g. `example.com`).

`cloudflare.tf`:

```hcl
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
```

**Create the API token yourself** (Cloudflare dashboard → My Profile → API Tokens → Create Token → "Edit zone DNS" template → Zone Resources: Include → Specific zone → your domain). Never use the global API key. Put the token and zone name in `terraform.tfvars` (gitignored) by editing the file directly, not by pasting the token into a chat. NS records have no proxy toggle, so there is nothing to set there. This delegates only the subdomain; the rest of the domain stays on Cloudflare untouched.

This is a deliberate exception to "no long-lived credentials" (like the Grafana CloudWatch user in Task 17): Cloudflare has no OIDC federation for this. Task 15 stores it as a GitHub secret.

- [x] **Step 7: Apply the rest and verify cert validation**

Run: `terraform apply -var-file=terraform.tfvars`
Expected: apply completes; `aws acm describe-certificate --certificate-arn <arn> --query 'Certificate.Status'` returns `"ISSUED"` within a few minutes of the NS delegation propagating (the ACM validation resource waits for it, so a single apply normally covers both; re-run if it times out — DNS propagation is the one step gated by something outside AWS and Terraform).

- [x] **Step 8: Commit**

```bash
git add dns.tf variables.tf example.tfvars
git commit -m "Add Route 53 hosted zone and ACM certificate for Fleet subdomain"
```

---

### Task 3: Fleet application stack — VPC + Aurora + Redis + ALB + Fargate (root module)

This is the milestone task: after this, Fleet is live and publicly reachable. One module call provisions everything — VPC included.

**Files:**
- Create: `secrets.tf` (the externalized Fleet server private key)
- Create: `installers.tf` (the externalized software-installers bucket + its IAM policy)
- Create: `fleet.tf`
- Create: `outputs.tf`

**Interfaces:**
- Consumes: `aws_acm_certificate_validation.fleet.certificate_arn`, `aws_route53_zone.fleet.zone_id`, `var.rds_snapshot_identifier`.
- Produces: `module.fleet.byo-vpc.byo-db.alb.lb_dns_name`, `module.fleet.byo-vpc.byo-db.alb.arn` / `lb_arn_suffix`, `module.fleet.byo-vpc.rds.cluster_members`, `module.fleet.byo-vpc.redis.member_clusters`, `aws_secretsmanager_secret.fleet_server_private_key.arn`, `aws_iam_policy.software_installers.arn` (must stay in `extra_iam_policies` in every later `fleet_config` edit — Tasks 6, 12), output `fleet_url` — consumed by Tasks 4, 5, 6, 8, 12, and `scripts/up.sh` in Task 14.

- [x] **Step 1: Write `secrets.tf` and `installers.tf`** — the two things that hold state and must survive `module.fleet` being destroyed on teardown (see Task 14).

`secrets.tf` — the Fleet server private key. This mirrors what the module would otherwise generate and own itself (verified against `byo-ecs`'s source: `random_password { length = 32, special = true }`). It encrypts sensitive data in the database, so losing it makes a restored snapshot unreadable: `prevent_destroy` guards it against a full `terraform destroy` (the `down` script uses `-target`, so it's unaffected; to genuinely delete it, remove the guard first). An earlier draft had `recovery_window_in_days = 0` (instant, unrecoverable deletion) and a pointless `create_before_destroy` on a fixed secret name — both removed.

```hcl
resource "random_password" "fleet_server_private_key" {
  length  = 32
  special = true

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_secretsmanager_secret" "fleet_server_private_key" {
  name                    = "fleet-homelab/fleet-server-private-key"
  recovery_window_in_days = 30

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_secretsmanager_secret_version" "fleet_server_private_key" {
  secret_id     = aws_secretsmanager_secret.fleet_server_private_key.id
  secret_string = random_password.fleet_server_private_key.result
}
```

`installers.tf` — the software-installers bucket. Verified against `byo-ecs`'s source: by default the module creates this bucket *inside* `module.fleet` with `force_destroy = true`, so every `down` would empty and delete it while the restored database still references those installers. With `create_bucket = false` the module also attaches **no** S3 permissions to the task role, so the policy below is what grants them (via `extra_iam_policies`). The name starts with `fleet-homelab-` so Task 15's `fleet-homelab-*` S3 scoping covers it.

```hcl
resource "aws_s3_bucket" "software_installers" {
  bucket = "fleet-homelab-software-installers-${data.aws_caller_identity.current.account_id}"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "software_installers" {
  bucket                  = aws_s3_bucket.software_installers.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "software_installers_bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.software_installers.arn, "${aws_s3_bucket.software_installers.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "software_installers" {
  bucket = aws_s3_bucket.software_installers.id
  policy = data.aws_iam_policy_document.software_installers_bucket.json
}

data "aws_iam_policy_document" "software_installers_task" {
  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject*", "s3:PutObject*", "s3:ListBucket*", "s3:DeleteObject",
      "s3:CreateMultipartUpload", "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts", "s3:GetBucketLocation",
    ]
    resources = [aws_s3_bucket.software_installers.arn, "${aws_s3_bucket.software_installers.arn}/*"]
  }
}

resource "aws_iam_policy" "software_installers" {
  name   = "fleet-homelab-software-installers"
  policy = data.aws_iam_policy_document.software_installers_task.json
}
```

The same reasoning was checked against the other buckets: the Firehose/S3 log buckets (Task 12) and the state bucket already live outside `module.fleet` and are untouched by `down`.

- [x] **Step 2: Write `fleet.tf`**

```hcl
module "fleet" {
  source = "github.com/fleetdm/fleet-terraform?depth=1&ref=tf-mod-root-v1.31.1"

  certificate_arn = aws_acm_certificate_validation.fleet.certificate_arn

  vpc = {
    name = "fleet-homelab"
    # db.t4g.medium (Aurora MySQL 3.08) is only orderable in us-east-1c and us-east-1f.
    # Keep BOTH in the set (the module wants three zones in total). 1f sits in 1b's old
    # slot: subnets are matched to zones by position.
    azs = ["us-east-1a", "us-east-1f", "us-east-1c"]
  }

  ecs_cluster = {
    cluster_name = "fleet-homelab"
  }

  alb_config = {
    name         = "fleet-homelab"
    idle_timeout = 905
  }

  rds_config = {
    name           = "fleet-homelab"
    instance_class = "db.t4g.medium"
    replicas       = 1
    db_parameters = {
      sort_buffer_size = 8388608
    }
    snapshot_identifier = var.rds_snapshot_identifier

    # Restore-from-snapshot compatibility: the module defaults are
    # monitoring_interval = 10 and Performance Insights on, and Fleet's own
    # byo-vpc/scripts/rds_storage_kms_migration.sh notes that
    # RestoreDBClusterFromSnapshot rejects both for non-Limitless Aurora.
    # This stack is restored from a snapshot on every rebuild (Task 14), so
    # both are off. Not reproduced here — see the note below the code block.
    monitoring_interval = 0
    observability = {
      performance_insights_enabled = false
    }
  }

  redis_config = {
    name          = "fleet-homelab"
    instance_type = "cache.t4g.small"
    cluster_size  = 1
    parameter = [
      { name = "client-output-buffer-limit-pubsub-hard-limit", value = 0 },
      { name = "client-output-buffer-limit-pubsub-soft-limit", value = 0 },
      { name = "client-output-buffer-limit-pubsub-soft-seconds", value = 0 },
    ]
  }

  fleet_config = {
    image = "fleetdm/fleet:v4.92.0"
    cpu   = 512
    mem   = 4096

    private_key_secret_arn = aws_secretsmanager_secret.fleet_server_private_key.arn

    software_installers = {
      create_bucket = false
      bucket_name   = aws_s3_bucket.software_installers.bucket
    }
    extra_iam_policies = [aws_iam_policy.software_installers.arn]

    autoscaling = {
      min_capacity = 1
      max_capacity = 2
    }

    extra_environment_variables = {
      FLEET_LICENSE_KEY          = var.fleet_license_key
      FLEET_LOGGING_JSON         = "true"
      FLEET_MYSQL_MAX_OPEN_CONNS = "10"
      FLEET_REDIS_MAX_OPEN_CONNS = "50"
    }
  }
}

# Fleet refuses to start until the database schema is migrated, and nothing
# in the root module runs migrations. This addon scales the service to 0,
# runs `fleet prepare db` as a one-off Fargate task, then scales back up —
# and re-triggers whenever the task definition revision changes, so it also
# covers Fleet image bumps and the first boot after a snapshot restore.
# Copied from upstream example/main.tf (tf-mod-addon-migrations-v2.3.0).
module "migrations" {
  source                   = "github.com/fleetdm/fleet-terraform/addons/migrations?depth=1&ref=tf-mod-addon-migrations-v2.3.0"
  ecs_cluster              = module.fleet.byo-vpc.byo-db.byo-ecs.service.cluster
  task_definition          = module.fleet.byo-vpc.byo-db.byo-ecs.task_definition.family
  task_definition_revision = module.fleet.byo-vpc.byo-db.byo-ecs.task_definition.revision
  subnets                  = module.fleet.byo-vpc.byo-db.byo-ecs.service.network_configuration[0].subnets
  security_groups          = module.fleet.byo-vpc.byo-db.byo-ecs.service.network_configuration[0].security_groups
  ecs_service              = module.fleet.byo-vpc.byo-db.byo-ecs.service.name
  desired_count            = module.fleet.byo-vpc.byo-db.byo-ecs.appautoscaling_target.min_capacity
  min_capacity             = module.fleet.byo-vpc.byo-db.byo-ecs.appautoscaling_target.min_capacity
  max_capacity             = module.fleet.byo-vpc.byo-db.byo-ecs.appautoscaling_target.max_capacity

  depends_on = [
    module.fleet,
  ]
}

# ECS Container Insights writes to this log group and AWS auto-creates it
# untagged, where it outlives `terraform destroy`. Declaring it here means it
# gets the default tags and is removed on teardown. (No depends_on needed:
# metrics only start flowing minutes after the cluster has tasks.) The name embeds
# the cluster name, so it comes from the same `local.cluster_name` as
# `ecs_cluster.cluster_name` in module "fleet" (a `locals` block at the top of fleet.tf).
resource "aws_cloudwatch_log_group" "container_insights" {
  name              = "/aws/ecs/containerinsights/${local.cluster_name}/performance"
  retention_in_days = 1
}

resource "aws_route53_record" "fleet_alb" {
  zone_id = aws_route53_zone.fleet.zone_id
  name    = var.fleet_subdomain
  type    = "A"

  alias {
    name                   = module.fleet.byo-vpc.byo-db.alb.lb_dns_name
    zone_id                = module.fleet.byo-vpc.byo-db.alb.lb_zone_id
    evaluate_target_health = true
  }
}
```

Why this is the whole module call, and nothing more: the `vpc` object's own defaults are `cidr = "10.10.0.0/16"`, `private_subnets = ["10.10.1.0/24", "10.10.2.0/24", "10.10.3.0/24"]`, matching `public_subnets`/`database_subnets`/`elasticache_subnets` in the same `10.10.x.0/24` pattern, and `enable_nat_gateway = true` / `single_nat_gateway = true` — every one of these is already exactly what this deployment wants. The only default worth overriding is `azs`, which defaults to `us-east-2a/b/c`. An earlier draft of this task re-typed all of those default values verbatim in a hand-written `vpc.tf` plus a separate `byo-vpc` module call — that split only existed to support a NAT-off, public-subnet Fargate configuration this plan no longer uses. Root's `main.tf` shows `byo-vpc`'s `redis_config.allowed_cidrs` gets set automatically to `module.vpc.private_subnets_cidr_blocks` and `rds_configs[...].subnets`/`redis_config.subnets`/`alb_config.subnets` all get wired from the VPC's own subnet outputs — all boilerplate this plan no longer has to hand-write.

**Path detail, verified against the module source, not guessed**: the root module's own `outputs.tf` exposes `vpc` and `byo-vpc` (the whole nested submodule) — not `alb` directly. `byo-vpc`'s own outputs, in turn, expose `byo-db` (not `alb` directly either) — `byo-db` is where the real `alb` output lives. So the full path from this root config is `module.fleet.byo-vpc.byo-db.alb.*`, used here and in Tasks 4 and 5. The hyphenated `byo-vpc`/`byo-db` attribute access is valid HCL — Fleet's own module source uses this exact pattern internally.

**Re-checked immediately before execution, not left stale from when this plan was first drafted**: the root module ref and Fleet image version above were bumped from `tf-mod-root-v1.31.0`/`fleetdm/fleet:v4.91.1` to the current `tf-mod-root-v1.31.1`/`fleetdm/fleet:v4.92.0` after diffing what changed between those two module tags. That one-patch bump turned out to matter: it moves `alb_config.tls_policy`'s default from `ELBSecurityPolicy-TLS13-1-2-2021-06` to `ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09` — a post-quantum-resistant TLS policy AWS added relatively recently — which this deployment gets for free since `alb_config` here never overrides `tls_policy`. `v4.92.0` is Fleet's actual latest stable release (verified against Fleet's own releases page), not just "one version newer."

`rds_config.name` and `redis_config.name` are both explicitly set to `"fleet-homelab"` — both default to just `"fleet"` if omitted, which would silently break every later reference to cluster/replication-group identifier `fleet-homelab` (`down.sh` in Task 14 identifies resources by this name directly; Task 17's Grafana alert rules use real member IDs from module outputs instead, so they aren't affected by this name).

**Corrections from an independent review of this task, each checked against upstream source:**
- **`replicas` is the total instance count, not the reader count.** `replicas = 0` would create an Aurora cluster with no instances. It is `1` here (one writer, no reader — the "no read replicas" decision is unchanged).
- **Migrations weren't running.** An earlier draft claimed migrations "run on first boot"; Fleet's `serve` exits when the schema is unmigrated, and the root module runs no migration. The `migrations` addon above is what Fleet's own example uses. It shells out to the AWS CLI (`local-exec`), so whatever machine runs `terraform apply` needs `bash` and the AWS CLI installed (the Task 15 runner installs it), and its role needs `ecs:RunTask`/`iam:PassRole`/`application-autoscaling:RegisterScalableTarget`. On a brand-new stack the service crash-loops briefly until the addon finishes — expected; the ECS service has no wait-for-steady-state, so `apply` doesn't hang on it.
- **`FLEET_SERVER_URL` removed.** It isn't a Fleet server config key (not in `server/config/config.go`); the "Fleet web address" is an app-config setting, entered in the first-run setup wizard and later managed by GitOps (`org_settings.server_settings.server_url`, Task 11), and it's what SES/MDM links are built from.
- **Software installers live outside the module** (Step 1) so teardown doesn't delete files the restored database still references.
- **Restore vs monitoring/Performance Insights.** Upstream's own comment says AWS rejects both on `RestoreDBClusterFromSnapshot` for non-Limitless Aurora; I did not reproduce that against AWS. Turning both off is harmless either way (this deployment has no use for them; the monitoring addon uses plain CloudWatch metrics), and if a restore ever complains about them, check these two settings first.
- **Restore mechanics that Task 14 relies on, verified in `terraform-aws-rds-aurora` v9.16.1:** `snapshot_identifier` is in the cluster's `ignore_changes`, so a later `apply` (including Task 16's plan without the variable) doesn't propose replacing the cluster. The master password is generated inside `module.fleet` and destroyed with it, so each rebuild gets a fresh one wired to the module's own Secrets Manager entry; that the provider applies it to the restored cluster is expected behaviour I did not reproduce — the Task 14 smoke test (Fleet connects after a restore) is the proof.
- **Transitive version note:** the module's Redis dependency (`cloudposse/elasticache-redis/aws`) is constrained `>= 1.9.1`, so `terraform init` resolves it to the newest release (2.1.0 at the time of writing), and `.terraform.lock.hcl` doesn't pin modules. If `plan` errors on a Redis input, that's the first suspect.

- [x] **Step 3: Write `outputs.tf`** — `scripts/up.sh` (Task 14) reads `terraform output -raw fleet_url`, so this needs to actually exist.

```hcl
output "fleet_url" {
  value = "https://${var.fleet_subdomain}"
}
```

- [x] **Step 4: Init, validate, pre-create the secret, and plan**

**Two-phase apply (required, found by running it).** On a fresh state, a plain `plan` fails with `Invalid count argument` in `byo-ecs/main.tf` (`count = local.private_key_secret_is_module_managed ? 1 : 0`): the module decides whether it manages the private key by checking whether `private_key_secret_arn` is null, and our externalized secret's ARN is unknown until the secret exists. Create the secret chain first:

`terraform apply -var-file=terraform.tfvars -target=aws_secretsmanager_secret_version.fleet_server_private_key`
Expected: `3 added` (random_password, secret, version). This is only needed once — the secret survives teardown (`prevent_destroy`), so rebuilds skip it.

Then run: `terraform init && terraform fmt && terraform validate && terraform plan -var-file=terraform.tfvars -out=tfplan`
(`init` is required first — this step adds new modules and the `random`/`null` providers, and `validate` fails with "Module not installed" without it. The same applies to every later task that adds a module or provider.)
Expected: `Plan: 86 to add, 0 to change, 0 to destroy` (after the secret pre-creation above): a new VPC (12 subnets, one NAT Gateway, one EIP), an Aurora cluster with **1 instance** (`fleet-homelab-one`), a Redis replication group (1 node), the ALB, target group, ECS cluster/service/task definition, the private key secret, the software-installers bucket + policy, and the migrations `null_resource`.

- [x] **Step 5: Apply**

Run: `terraform apply tfplan`
Expected: apply completes (10+ minutes — Aurora cluster creation and NAT Gateway provisioning dominate, then the migrations addon runs `fleet prepare db` as a one-off task and scales the service back up, adding a few minutes).

**Availability zones matter for Aurora capacity (found on the rebuild of 2026-10-03).** The first rebuild failed on the Aurora *instance* with `InvalidVPCNetworkStateFault: … no subnets exist in Availability Zones with sufficient capacity for … db.t4g.medium … choose from these Availability Zones: us-east-1f`. For Aurora MySQL 3.08, `db.t4g.medium` is only *orderable* in `us-east-1c` and `us-east-1f` (`aws rds describe-orderable-db-instance-options --engine aurora-mysql --engine-version 8.0.mysql_aurora.3.08.2 --db-instance-class db.t4g.medium`); the original zone set `1a/1b/1c` only ever worked because Aurora always placed the instance in `1c`, and `1c` ran out of spare capacity. The restored cluster itself was fine and no data was at risk. The fix is to keep **both** orderable zones in `vpc.azs` (above). To diagnose a similar failure, read the full apply log (the first line of the error names the cause) and check which zones can order the class. **Do not change `azs` on a live stack:** the VPC module derives each subnet's CIDR from its slot, so a swapped zone creates a new subnet with the *same* CIDR before the old one is deleted and AWS rejects it (`InvalidSubnet.Conflict`), and the old subnets can't go first while the ALB, DB, and cache subnet groups still reference them. Destroy and rebuild instead — safe here because the database comes back from the snapshot. Also keep the apply log: I once deleted it in a cleanup step and had to reconstruct the error from AWS.

**Teardown note (found on the first real destroy):** after `terraform destroy`, AWS re-creates the Container Insights log group `/aws/ecs/containerinsights/fleet-homelab/performance` (untagged) because the cluster is still emitting metrics as it shuts down. Left behind, it makes the next apply fail with `ResourceAlreadyExistsException`. Delete it after every destroy (`aws logs delete-log-group --log-group-name /aws/ecs/containerinsights/fleet-homelab/performance`); Task 14's `down.sh` does this. A `depends_on` on the log group can't fix it — on create it would make Terraform try to make the group *after* the tasks have already caused AWS to create it. Aurora's automated `rds:fleet-homelab-…` snapshot for the deleted cluster also lingers for a few minutes and then removes itself.

**Expect one retry — now automatic, not manual (reproduced on 3 of 3 real builds).** The first `apply` fails near the end with `NoSuchEntity: The role with name fleet-role cannot be found` on `aws_iam_role_policy_attachment.extras[0]` — IAM is eventually consistent, and the module attaches our software-installers policy the instant the role is created, sometimes before IAM has replicated the role everywhere. Nothing is wrong: the role exists seconds later. This isn't retried by the AWS provider itself (`NoSuchEntity` isn't classified as a throttling/retryable error), and it's not fixable inside the pinned upstream module without forking it, so `scripts/tf-apply.sh` (written ahead of Task 14, since every apply from here on benefits from it) wraps `terraform apply`, detects this specific error, waits 20s, and re-plans/re-applies automatically:

```bash
terraform apply -var-file=terraform.tfvars -out=tfplan
./scripts/tf-apply.sh tfplan -- -var-file=terraform.tfvars
```

On the initial build this resolves **4 to add** (the attachment, the RDS ingress rule, the `fleet_alb` DNS record, and the migrations `null_resource`); on a snapshot-restore rebuild it resolved **5 to add** (also the WAF Web ACL association, and a second `extras[]` index since Tasks 6-8 add more `extra_iam_policies`/`extra_execution_iam_policies`). Either way, `scripts/tf-apply.sh` handles it without a human needing to notice and re-run — use it (not a bare `terraform apply`) for every apply in this plan from here on, including inside Task 14's `up.sh`/`down.sh` and Task 15's CI workflow.

- [x] **Step 6: Verify the ECS service is healthy**

Run: `aws ecs describe-services --cluster fleet-homelab --services fleet --query 'services[0].{running:runningCount,desired:desiredCount}'`
Expected: `{"running": 1, "desired": 1}`

- [x] **Step 7: Verify Fleet is reachable over HTTPS**

Run: `curl -sI https://<fleet_subdomain>/healthz`
Expected: `HTTP/2 200`

- [x] **Step 8: Initialize Fleet and create the break-glass admin — in the browser, the way an organization normally does it.** A freshly deployed Fleet has no users at all: opening `https://<fleet_subdomain>/` redirects to `/setup` (seen on this deployment: the redirect and the page load), where you create the first global admin. Every later task (MDM in Task 8, SSO in Tasks 10-11, GitOps, Grafana) needs this login. **No `fleetctl` is needed for this** — Fleet's own AWS/Terraform deployment guide never mentions it either (checked; that guide also says nothing about creating the first user or about migrations, so it is not a complete recipe). Read what the form asks for and fill it in: your name, an email address you control, a strong password, and the organization name (`Homelab`), and confirm the server URL it shows.

Store the password in your personal password manager (not Secrets Manager — this account has to work even if AWS itself is the problem). This is a one-time action per database: because Aurora is restored from snapshot on every `up` (Task 14), the account survives teardown/rebuild. It only needs redoing after a genuinely fresh database (a `--fresh` `up`). Turning on MFA for this account is deliberately deferred to Task 9, after SSO is proven working.

(The CLI equivalent, if you ever want it: `fleetctl config set --address https://<fleet_subdomain>` then `fleetctl setup --email <email> --name "Break Glass Admin" --org-name "Homelab"` — verified against Fleet v4.92.0's source; it prompts for the password. Not used here.)

- [x] **Step 8a: 🎓 You run this — install `fleetctl`, log in, and get oriented. Do this whenever you're ready; the first hard requirement is Task 8 Step 5 (or Task 11 Step 1, whichever you reach first), not now.** ⛔ Gate: before any later step that runs `fleetctl`, check `which fleetctl && fleetctl --version`; if it isn't installed at 4.92.0, stop and do this step (it is deliberately not installed earlier). `fleetctl` is Fleet's CLI, the way `aws` is AWS's: a client on your Mac that talks to Fleet's API over HTTPS (it is not installed on AWS or inside the server). Install the same version as the server, log in as the admin you created in Step 8, then look around:

```bash
npm install -g fleetctl@4.92.0     # or run any command as: npx fleetctl@4.92.0 <command>
fleetctl --version                 # should print 4.92.0
fleetctl --help                    # the top-level command list: setup, login, get, apply, gitops, user, query, ...
fleetctl get --help                # what "get" can list (hosts, queries, labels, teams/fleets — the names shift between versions, trust the help output)
fleetctl config --help             # contexts: like AWS profiles, one per Fleet instance

fleetctl config set --address https://<fleet_subdomain>
fleetctl login --email <the admin email from Step 8>    # prompts for the password; verify the flags with `fleetctl login --help`
```

`config set --address` saves the server URL in `~/.fleet/config` under a context named `default` (like an AWS profile); `login` exchanges your email and password for a session token and stores it in that context, so later commands are authenticated. That token is a session token and expires (by default after days) — re-run `fleetctl login` when commands start returning 401, and never use a login token for CI (Task 11 uses an API-only user for that).

- [ ] **Step 8b: 🎓 You run this — poke around the live server** (needs Step 8a). Read-only commands to see what a brand-new Fleet contains and how the CLI shapes its output:

```bash
fleetctl config get                # which server/context/token you are using (token is masked)
fleetctl get config                # the server's full config as YAML — the same document GitOps will manage in Task 11
fleetctl get hosts                 # empty for now: nothing is enrolled yet
fleetctl get config --yaml | head  # add --yaml or --json to most `get` commands for machine-readable output
```

What to notice: `get config` shows `org_info`, `server_settings`, `sso_settings` (still disabled) and `mdm` — every setting Tasks 8, 10 and 11 will change, first by hand and later from Git. That's the mental model for GitOps: the YAML you push is this same config document.

- [x] **Step 9: Commit**

```bash
git add secrets.tf installers.tf fleet.tf outputs.tf .terraform.lock.hcl
git commit -m "Deploy Fleet (VPC + Aurora + Redis + ALB + Fargate) via the root module"
```

---

**Aurora engine version is pinned, and was upgraded in place on 2026-10-03.** The Fleet module defaults to Aurora MySQL 3.08.2 (MySQL 8.0.39), which is below Fleet's stated minimum (MySQL 8.0.44, per Fleet's docs; its CI runs 8.0.44 on every change and 8.4.8 nightly) and which AWS ends standard support for on 2026-08-31 (3.08/3.09), after which it force-upgrades the cluster and any instance restored from a 3.08/3.09 snapshot. `fleet.tf` now sets `rds_config.engine_version = "8.0.mysql_aurora.3.13.0"` (MySQL 8.0.45). Done as a minor in-place upgrade of the running cluster (3.08.2 -> 3.13.0 is a valid non-major target): a tagged manual snapshot first (`fleet-homelab-preupgrade-<timestamp>`), a plan of two in-place changes and no replacements, then apply (about 3.5 minutes; the cluster modify took 3m04s, the instance 31s). Verified afterwards: cluster and instance report 3.13.0 and available, no pending maintenance, ECS 1/1 with the rollout COMPLETED, `/healthz` and `/` both 200 (the admin survived), and a re-plan shows no changes. Not done: moving to the Aurora MySQL 8.4 line (a major upgrade with new parameter-group families; Fleet tests 8.4.8 nightly only). Revisit when Aurora 3 nears its own end of standard support. Check the Aurora and Fleet release notes before bumping the pin, and keep it at or above Fleet's stated minimum.

**Aurora instance class is now `db.t3.medium` (2026-10-04).** The first rebuild from the 3.13.0 snapshot failed three times in a row with `InsufficientDBInstanceCapacity` for `db.t4g.medium` ("no Availability Zones with sufficient capacity"), although the API reported the class orderable in every zone. The stack was left half built (cluster restored fine, no instance) and kept failing across retries minutes apart. Switching to `db.t3.medium` (same 2 vCPU / 4 GiB, x86 instead of ARM; roughly $0.082/h versus $0.095/h by the Pricing API, first price record only) succeeded on the next apply: instance created in us-east-1f, 27 resources added, re-plan clean, ECS 1/1, target healthy, `/healthz` and `/` both 200 (admin survived the restore into 3.13.0). Lesson: "orderable" is not "has capacity", and the instance class is the lever, not the zone list (do not change `azs` on a live or partial stack). If t3 also runs short, db.t4g.large and db.r6g.large are orderable but double the cost. The IAM role-propagation race (`NoSuchEntity fleet-role`) appeared twice in the log and was retried automatically by `tf-apply.sh`.

### Task 4: WAF on the ALB

**Second rule, for CI (2026-10-06): `allow-ci-header` at priority 0, ahead of `allow-us`.** GitHub-hosted runners run in Azure regions worldwide, so the GitOps workflow was blocked whenever its runner was outside the US (seen: HTTP 403, WAF sample country MX). Requests whose `x-fleet-ci` header exactly matches `var.waf_ci_header_value` (sensitive, at least 32 characters, in the gitignored `terraform.tfvars`; also the GitOps repo secret `FLEET_CI_HEADER`) are allowed regardless of country; everything else still needs a US source, and Fleet still requires an API token. Sampled requests are off for that rule, since samples would record the header value. Allow-listing GitHub's published runner ranges (about 7,000 CIDRs) was rejected: it would admit anyone using GitHub Actions and changes constantly. Verified: after the change a run succeeded and the rule's `AllowedRequests` metric counted its requests. **Rotate:** new value in `terraform.tfvars`, apply, then update the GitHub secret.

**Files:**
- Create: `waf.tf`

**Interfaces:**
- Consumes: `module.fleet.byo-vpc.byo-db.alb.arn`.

- [x] **Step 1: Write `waf.tf`**

**Built as a custom `aws_wafv2_web_acl`, not Fleet's `waf-alb` addon** — found while executing this task, not planned this way from the start. The addon (`addons/waf-alb`) only supports "block these specific countries/IPs, default-allow the rest" or "allow these specific IPs, default-block the rest" (verified in its `variables.tf`/`main.tf`); there's no "allow only this one country" mode. What I actually want — US-only access — doesn't fit either mode well: a blocklist of every non-US country hit a real AWS limit (`geo_match_statement.country_codes` allows at most 50 entries per statement — confirmed by a failed `apply`) long before it hit AWS's own `CountryCode` enum of 250 codes, and even if that limit didn't exist, a maintained "block everyone except US" list would silently *allow* any country AWS adds in the future until the list is updated. An allow-only-US rule with a default block action is simpler (one country code, not 249), avoids the limit entirely, and needs no upkeep as AWS adds countries — so this task built that directly instead of forcing it through the addon.

```hcl
resource "aws_wafv2_web_acl" "fleet_homelab" {
  name        = "fleet-homelab"
  description = "Allow US traffic only, block everything else by default"
  scope       = "REGIONAL"

  default_action {
    block {}
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
```

**`description` has an undocumented (in the Terraform provider) character restriction** — AWS rejects `;` (and likely other punctuation outside `[\w+=:#@/\-,.\s]`); found by a failed apply, fixed by dropping the semicolon. **The Web ACL association can fail once with `WAFUnavailableEntityException: AWS WAF couldn't retrieve the resource that you requested`** even though the ACL was just created successfully — transient, found on this exact apply; a re-run of `terraform apply -target=aws_wafv2_web_acl_association.fleet_homelab` (the ACL itself is already in state, so nothing else re-runs) succeeds. If a stricter geo-blocking posture is wanted later (e.g. resuming Fleet's own addon for its narrower blocklist use case, or adding IP-based rules for MDM/webhook callers that might not originate from US IPs), revisit rather than assume this design covers those cases.

- [x] **Step 2: Init, validate, and plan**

Run: `terraform init && terraform fmt && terraform validate && terraform plan -var-file=terraform.tfvars -out=tfplan`
Expected: plan shows one `aws_wafv2_web_acl` (with a geo-match blocking rule listing 249 country codes) and one `aws_wafv2_web_acl_association`, plus the addon's supporting `aws_wafv2_rule_group`s and `aws_wafv2_ip_set`s (all named `fleet-homelab`).

- [x] **Step 3: Apply**

Run: `terraform apply tfplan`

- [x] **Step 4: Verify**

Run: `aws wafv2 list-web-acls --scope REGIONAL --query "WebACLs[?Name=='fleet-homelab']"`
Expected: one Web ACL returned.

Then confirm it's actually associated with the ALB (the association is a separate resource and can fail independently, per the note above — a listed ACL alone doesn't prove it's attached):
`aws wafv2 get-web-acl-for-resource --resource-arn $(aws elbv2 describe-load-balancers --names fleet-homelab --query 'LoadBalancers[0].LoadBalancerArn' --output text) --query 'WebACL.Name' --output text`
Expected: `fleet-homelab`. Also re-check `https://<fleet_subdomain>/healthz` still returns 200 from a US location — a mistake in the geo rule would show up as Fleet suddenly unreachable, not as a Terraform error.

- [x] **Step 5: Commit**

```bash
git add waf.tf .terraform.lock.hcl
git commit -m "Attach a US-only AWS WAF Web ACL to the Fleet ALB"
```

---

### Task 5: Monitoring addon

**Superseded — folded into Task 17, not a separate task to execute.** Originally a standalone CloudWatch-alarms-plus-SNS design. Reconsidered after I pointed out the overlap with the Grafana dashboard (Task 17): Grafana OSS has its own native alerting (verified against Grafana's own docs — not Enterprise-gated, and CloudWatch is an explicitly supported data source for Grafana-managed alert rules), so a second, separate CloudWatch-alarm system alongside it would be redundant. Task 17 now builds alerting directly on the same CloudWatch queries the dashboard already uses, with email delivered through Task 6's SES domain identity (a dedicated SES-SMTP IAM user, distinct from Fleet's own SES/API sending path). See Task 17 Steps 11-16.

---

### Task 6: SES for outbound mail

**Files:**
- Create: `ses.tf`

**Interfaces:**
- Consumes: `aws_route53_zone.fleet.zone_id` (for DKIM/verification records).

- [x] **Step 1: Write `ses.tf`**

```hcl
module "ses" {
  source = "github.com/fleetdm/fleet-terraform//addons/ses?depth=1&ref=tf-mod-addon-ses-v1.5.0"

  domain  = var.fleet_subdomain
  zone_id = aws_route53_zone.fleet.zone_id
}
```

- [x] **Step 2: Init, validate, plan, apply**

Run: `terraform init && terraform fmt && terraform validate && terraform plan -var-file=terraform.tfvars -out=tfplan && terraform apply tfplan`

- [x] **Step 3: Verify domain identity is verified, and check for the SES sandbox**

Run: `aws sesv2 get-email-identity --email-identity <fleet_subdomain> --query 'VerifiedForSendingStatus'`
Expected: `true` (may take a few minutes after DNS records propagate — re-run if `false`).

Then: `aws sesv2 get-account --query 'ProductionAccessEnabled'`. If `false`, the account is in the **SES sandbox** (the default for a new account/region): SES will only deliver to individually *verified recipient* addresses, so Fleet's invite/MFA/password-reset mail to your own inbox will silently fail. Two fixes, either is fine: (a) a one-time `aws sesv2 create-email-identity --email-identity <your email>` and click the link SES emails you — this identity is account-level, not part of this Terraform, so it persists across teardown; or (b) request production access in the SES console (a support-style form, typically about a day). Break-glass MFA (Task 9) depends on this working.

`module.ses` is deliberately **not** torn down by `down.sh` (Task 14): it costs nothing at rest, and re-creating the identity/DKIM records every session would mean re-verification on every `up`. An earlier draft tore it down.

- [x] **Step 4: Merge the SES addon's outputs into `fleet.tf`'s `fleet_config`.** The SES addon follows the same `fleet_extra_environment_variables` / `fleet_extra_iam_policies` convention as the MDM and logging addons — replace the plain `extra_environment_variables` map in `fleet.tf`'s `fleet_config` block with:

```hcl
    extra_environment_variables = merge(
      {
        FLEET_LICENSE_KEY          = var.fleet_license_key
        FLEET_LOGGING_JSON         = "true"
        FLEET_MYSQL_MAX_OPEN_CONNS = "10"
        FLEET_REDIS_MAX_OPEN_CONNS = "50"
      },
      module.ses.fleet_extra_environment_variables
    )
    extra_iam_policies = concat(
      [aws_iam_policy.software_installers.arn],
      module.ses.fleet_extra_iam_policies
    )
```

(`FLEET_SERVER_URL` is gone from this map — it isn't a real Fleet config key, see Task 3. `aws_iam_policy.software_installers` is Task 3's policy; it has to stay in this list or the task loses access to its installers bucket.)

- [x] **Step 5: Re-apply**

Run: `terraform fmt && terraform validate && terraform apply -var-file=terraform.tfvars`
(A plain apply, not `-target=module.fleet`: changing `fleet_config` produces a new task-definition revision, and `module.migrations` must be in the same run to re-trigger off it.)

- [x] **Step 6: Commit**

```bash
git add ses.tf fleet.tf .terraform.lock.hcl
git commit -m "Add SES addon and wire Fleet to send email through it"
```

---

### Task 7: MDM addon — phase 1 (secret scaffolding)

**Fleet-side background (verified against Fleet v4.92.0 source and the `addons/mdm` module, replacing an earlier draft that assumed Apple's certificates lived in Secrets Manager):** Apple MDM is *not* configured through environment variables/secrets in this setup. Fleet generates its own SCEP CA and APNs private key server-side and stores them, encrypted with `FLEET_SERVER_PRIVATE_KEY`, in the database when you upload the Apple-issued APNs certificate in the Fleet UI (Task 8). Because Aurora is snapshot-restored on every `up` and the private key is externalized (Task 2/3), that configuration survives teardown with no Secrets Manager involvement. The only MDM material that *does* need to be supplied as a secret is the **Windows WSTEP identity certificate/key pair**, which the `addons/mdm` module reads from its `fleet-scep` secret (under Apple-named JSON keys — a quirk of the module) and maps onto `FLEET_MDM_WINDOWS_WSTEP_IDENTITY_CERT_BYTES`/`_KEY_BYTES`.

**Files:**
- Create: `mdm.tf`

**Interfaces:**
- Produces: one empty Secrets Manager secret (`fleet-scep`) that Task 8 populates with the Windows WSTEP pair, plus the module outputs `extra_secrets` / `extra_execution_iam_policies` that Task 8 wires into `fleet.tf`.

- [x] **Step 1: Write `mdm.tf`**

```hcl
module "mdm" {
  source = "github.com/fleetdm/fleet-terraform//addons/mdm?depth=1&ref=tf-mod-addon-mdm-v2.2.0"

  apn_secret_name    = null # Apple APNs cert is uploaded in the Fleet UI (Task 8), not via a secret
  scep_secret_name   = "fleet-scep"
  abm_secret_name    = null
  enable_apple_mdm   = false # keeps the Apple env vars out of the task definition
  enable_windows_mdm = true  # wires fleet-scep -> FLEET_MDM_WINDOWS_WSTEP_IDENTITY_*
}
```

- [x] **Step 2: Validate, plan, apply**

Run: `terraform fmt && terraform validate && terraform plan -var-file=terraform.tfvars -out=tfplan && terraform apply tfplan`
Expected: plan creates one Secrets Manager secret (`fleet-scep`) plus its IAM policy, empty; no APN or ABM secret because both are `null`. (The Fleet task is not touched yet — the secret isn't wired in until Task 8, after it has content. An ECS task whose secret reference points at a missing JSON key fails to start, so the order matters.)

- [x] **Step 3: Verify**

Run: `aws secretsmanager describe-secret --secret-id fleet-scep --query Name`
Expected: `"fleet-scep"` prints without error.

- [x] **Step 4: Commit**

```bash
git add mdm.tf
git commit -m "Add MDM addon phase 1 (empty WSTEP secret, Windows MDM enabled)"
```

---

### Task 8: MDM — phase 2 (Windows WSTEP certificate + Apple push certificate)

Two independent halves: Part A (Windows, Terraform + `openssl`) and Part B (Apple, a manual UI runbook). Neither needs to repeat on a rebuild — the `fleet-scep` secret deliberately survives teardown (Task 14 excludes `module.mdm` from `down`'s destroy targets), and Apple's configuration lives in the database that Task 14 snapshots.

**Files:**
- Modify: `fleet.tf` (add `module.mdm.extra_secrets` / `extra_execution_iam_policies` into `fleet_config`)

**Part A — Windows MDM (WSTEP identity certificate)**

- [x] **Step 1: Generate the WSTEP certificate and key — exact commands from Fleet's own guide** (`fleetdm.com/guides/windows-mdm-setup`), fetched and verified directly against this machine's OpenSSL, not taken from memory. An earlier draft of this step improvised a generate-then-detect-and-convert approach; Fleet's guide does it in one line with `-traditional`.

```bash
mkdir -p ~/fleet-wstep && cd ~/fleet-wstep
openssl version   # confirm this is real OpenSSL, not macOS's stock LibreSSL (Fleet's own guide flags this exact gotcha — LibreSSL doesn't support -traditional; Homebrew's openssl, verified in this session, does)
openssl genrsa -traditional -out fleet-mdm-win-wstep.key 4096
head -1 fleet-mdm-win-wstep.key   # must read: -----BEGIN RSA PRIVATE KEY----- (PKCS#1, "traditional" format)
```

If your `openssl` turns out to be LibreSSL and rejects `-traditional`, fall back to: `openssl genrsa -out fleet-mdm-win-wstep.key 4096` then, if `head -1` shows `-----BEGIN PRIVATE KEY-----` (PKCS#8) instead, convert with `openssl rsa -in fleet-mdm-win-wstep.key -traditional -out fleet-mdm-win-wstep.key.new && mv fleet-mdm-win-wstep.key.new fleet-mdm-win-wstep.key`.

```bash
openssl req -x509 -new -nodes -key fleet-mdm-win-wstep.key -sha256 -days 3652 -out fleet-mdm-win-wstep.crt -subj '/CN=Fleet Root CA/C=US/O=Fleet.'
```

(`-nodes` is a no-op here specifically — it only matters when `req` generates a fresh key itself, and this one reads the existing `fleet-mdm-win-wstep.key` — included anyway to match Fleet's documented command exactly, in case that assumption is wrong on some OpenSSL version. `-days 3652` matches Fleet's guide precisely; the previous draft used `3650`, an immaterial ~2-day difference, but exact reuse of Fleet's own tested command is safer than a hand-derived approximation of it.)

**Back these two files up in your password manager / encrypted storage.** Fleet uses this pair to escrow BitLocker recovery keys for Windows hosts; replacing it later permanently loses access to keys already escrowed. Do not lose it and do not casually regenerate it.

- [x] **Step 2: Store the pair in the secret** (jq builds the JSON so the PEM newlines are escaped correctly):

```bash
jq -n --rawfile c fleet-mdm-win-wstep.crt --rawfile k fleet-mdm-win-wstep.key \
  '{FLEET_MDM_APPLE_SCEP_CERT_BYTES: $c, FLEET_MDM_APPLE_SCEP_KEY_BYTES: $k}' > payload.json
aws secretsmanager put-secret-value --secret-id fleet-scep --secret-string file://payload.json
shred -u payload.json 2>/dev/null || rm -P payload.json
```

(These JSON key names, `FLEET_MDM_APPLE_SCEP_CERT_BYTES`/`_KEY_BYTES`, are the `addons/mdm` module's Secrets-Manager-internal naming — verified in Task 7 against the module's own `outputs.tf`. Fleet's guide itself, written for a bare-metal/Docker deployment, has you set `FLEET_MDM_WINDOWS_WSTEP_IDENTITY_CERT_BYTES`/`_KEY_BYTES` directly as environment variables; here the module maps our secret\'s Apple-named keys into those same real env var names at the ECS task level, so the end state matches Fleet\'s guide even though the path there looks different.)

(The key names say "APPLE_SCEP" because that is what the `addons/mdm` module hard-codes; with `enable_windows_mdm = true` it re-exposes the same two values as the Windows WSTEP variables. Nothing Apple-related is happening here.)

- [x] **Step 3: Wire MDM's secrets into the Fleet task** — modify `fleet.tf`'s `fleet_config` block (extending, not replacing, Task 6's SES merge if it is already there — merge all module outputs into the same expression):

```hcl
    extra_secrets                = module.mdm.extra_secrets
    extra_execution_iam_policies = module.mdm.extra_execution_iam_policies
```

- [x] **Step 4: Validate, plan, apply**

Run: `terraform fmt && terraform validate && terraform plan -var-file=terraform.tfvars -out=tfplan && terraform apply tfplan`
Expected: the Fleet task definition is replaced and the service redeploys; then `aws ecs describe-services --cluster fleet-homelab --services fleet --query 'services[0].{running:runningCount,desired:desiredCount}'` returns running 1 / desired 1 and `curl -sI https://<fleet_subdomain>/healthz` returns `HTTP/2 200`.

Windows MDM itself is switched *on* declaratively in Task 11 (`controls.windows_enabled_and_configured: true` in `default.yml`), not here — this step only supplies the certificate it needs.

**Part B — Apple MDM (APNs push certificate), all through the Fleet UI**

- [ ] **Step 5: 🎓 You run this — generate the APNs CSR.** *(Pre-flight: `fleetctl --version` → 4.92.0 and still logged in — `fleetctl get config` works. Otherwise stop; see Task 3 Step 8a.)* (What it does: asks the Fleet server to create the Apple MDM SCEP CA and APNs key, then writes only the signing request to disk for you to upload to Apple.) With `fleetctl` installed and logged in (Task 3 Step 8a): `fleetctl generate mdm-apple --csr ~/fleet-apns.csr`. Verified against Fleet v4.92.0: this asks *the Fleet server* for the CSR (it generates the SCEP CA and APNs key server-side and keeps them in the database — nothing to store in AWS) and writes only the CSR to disk. Alternatively use Fleet UI > Settings > Integrations > Mobile device management (MDM) > Apple Push Certificates > "Add APNs".

  **Email caveat (verified in Fleet's source, not tested):** the CSR is signed via fleetdm.com using the *logged-in user's email address*, and fleetdm.com can reject the request with "Email domain '@…' is not permitted for APNS certificate signing. Please use a corporate or organization email address." The break-glass admin was created with your personal address; if that gets rejected, do this step while logged in as an SSO/Fleet user whose email is on your own domain (after Task 11 Step 8 — Apple MDM is not needed until you enroll a Mac, so postponing it is fine), or create a temporary admin on a domain-owned address. Which domains fleetdm.com rejects is not known — verify at execution.

- [ ] **Step 6: Manual — get the APNs cert from Apple.** Go to https://identity.apple.com/pushcert/, sign in with a **dedicated Apple Account you'll keep long-term** (the cert must be renewed with the same Apple ID every year — don't tie it to a throwaway), upload the CSR, download the resulting `.pem`.

- [ ] **Step 7: Manual — upload it in Fleet.** Fleet UI > Settings > Integrations > MDM > Apple Push Certificates > upload the `.pem`. Expected: Apple MDM shows "Connected" with a push certificate expiry about one year out. Put the expiry date in your calendar — an expired APNs cert breaks Apple MDM for every enrolled Mac.

- [ ] **Step 8: Verify.** In the Fleet UI, Apple MDM shows connected. Windows MDM will show enabled after Task 11 applies `windows_enabled_and_configured`.

- [ ] **Step 9: Commit**

```bash
git add mdm.tf fleet.tf
git commit -m "Wire MDM WSTEP secret into the Fleet task (Windows MDM)"
```

---

### Task 9: Harden the break-glass admin (MFA) — run this *after* Task 11 Step 8

**Ordering note:** the break-glass account itself is created in Task 3 Step 8 (`fleetctl setup`), because nothing in Fleet is usable before that. This task is the MFA hardening only, and it is deliberately placed *after* SSO is proven working (Task 11 Step 8) — MFA users cannot use `fleetctl login` (Fleet rejects it for MFA-enabled accounts, verified in source), and email-based MFA depends on SES delivering mail, so turning it on before SSO is a second way in would risk locking yourself out of an unconfigured instance. If you are executing tasks in numeric order, do Tasks 10 and 11 first, then come back here.

**Files:** none (operational).

- [x] **Step 1: Verify the break-glass login works as a plain password login** (before MFA changes anything).

Run: `curl -s -X POST https://<fleet_subdomain>/api/v1/fleet/login -H 'Content-Type: application/json' -d '{"email":"<email>","password":"<password>"}' | grep -o '"token"'`
Expected: `"token"` present in the response.

- [x] **Step 2: Decide whether to enable MFA at all.** This is a real trade-off, not a formality:
  - **Option A — enable email MFA (recommended if you're willing to keep SES delivery working).** Adds a second factor to the only password-only account.
  - **Option B — skip MFA and rely on a long random password + the WAF + SSO for daily use.** Simpler and cannot lock you out via email problems; the residual risk is a single-factor admin account on a public URL.

  Either is defensible; A is the plan's default. If you pick B, skip the rest of this task.

- [x] **Step 3: (Option A) Make SES able to deliver to your address.** This AWS account's SES is in the **sandbox** (`ProductionAccessEnabled=false`, checked live) — in the sandbox SES only delivers to *verified* recipient identities, so MFA emails to an unverified address would silently never arrive. The SES addon (Task 6) is destroyed and recreated on every `down`/`up`, so verify the recipient *outside Terraform* so it persists:

```bash
aws sesv2 create-email-identity --email-identity <your real email> --tags Key=Project,Value=fleet-lab Key=ManagedBy,Value=terraform   # then click the link in the verification email
aws sesv2 get-email-identity --email-identity <your real email> --query VerificationStatus   # expect "SUCCESS"
```

Also confirm the *sender* address Fleet uses (Task 6) is a verified identity or a verified domain — the recipient being verified is not enough. Send a test message before relying on it (e.g. `aws sesv2 send-email` from the sender to the recipient). Requesting SES production access from AWS is the alternative that removes this whole class of problem, at the cost of a support-case round trip.

- [x] **Step 4: (Option A) Enable MFA on the break-glass user.** Fleet UI > Settings > Users > the break-glass row > Edit > "Require multi-factor authentication" (Premium, email-based, requires SMTP — which Task 6 provides). MFA cannot be enabled on SSO or API-only users, which is fine here. Not verified: whether an account may enable MFA on itself or needs a second admin — check at execution; an SSO-provisioned Fleet Admins user (Task 11 Step 8) can do it for you.

- [x] **Step 5: (Option A) Test it now, while SSO is still your fallback.** Log out and log in as break-glass; expect an emailed magic link/confirmation. **Recovery notes:** if email breaks later (SES sandbox drift, sender identity gone after a rebuild), this account is locked out and you fall back to SSO; the local account can then only be repaired by another admin editing the user (or, worst case, database access). Also, `fleetctl` can no longer log in as this user — for any future CLI use, get an API token from the UI (My account > Get API token) and run `fleetctl config set --token <token>`. (Task 11's GitOps and Task 17's Grafana use dedicated API-only users, so neither depends on this account.)

- [x] **Step 6: No commit needed** — operational action, not code. The account and its MFA setting live in the database, so they survive the Aurora snapshot/restore cycle (Task 14). Only the SES *recipient identity* from Step 3 is separate state, and it too persists because it was created outside Terraform.

**Done 2026-10-04 (Option A, email MFA).** SSO (Okta) was proven first, so the precondition held. What it took, and what was learned:
- **SES:** the account is still in the sandbox (`ProductionAccessEnabled=false`). The break-glass mailbox was already a verified SES recipient (created earlier outside Terraform, so it persists across teardowns); the sender domain (the Fleet hostname) is verified with DKIM. A test sent with `aws sesv2 send-email` from the Fleet domain reached the mailbox.
- **Sender address:** Fleet's SMTP settings page only says "Email already configured" and has no sender field, because email is set through the server (`FLEET_EMAIL_BACKEND=ses`). From `server/mail/ses.go`: with the SES backend Fleet builds the From address itself as `do-not-reply@<server host>`, i.e. `do-not-reply@<fleet-hostname>`, covered by the verified domain identity. Nothing to configure.
- **Enabling:** done from an Okta-SSO admin session (the docs say to use a different admin), with that session kept open as the fallback. MFA is a per-user setting (`mfa_enabled`, Premium; incompatible with SSO and API-only users).
- **Test:** in a private window the break-glass user logged in with email and password, received the emailed link, and the link completed the login.
- **Remaining risk, unchanged:** if SES delivery breaks (sandbox drift, a lost verified recipient), the break-glass account is locked out and SSO is the way back in. `fleetctl login` no longer works for it; use an API token from the UI or an SSO admin.

---

### Task 10: Okta SSO — Terraform (`okta/`): SAML app, groups, role attribute

**Replaces the Entra design (decided 2026-10-03).** The Entra build worked end to end (assertion captured, Fleet login, role sync), then failed the one rule that matters: **nobody gets a Fleet role unless explicitly assigned.** Two defaults compounded, both verified:
- **Fleet (v4.92.0, `ee/server/service/users.go`):** with JIT on, a new user whose assertion carries no role is created as **global observer** ("If no roles are set in the SSO attributes, default to setting user as a global observer"). There is no setting that refuses such a login, and for an existing user a missing role leaves the old role untouched.
- **Entra:** Global Administrators sign in to an app regardless of "assignment required" (Microsoft's `application-properties.md`: "Users with a Global Administrator role can sign in to applications, regardless of the assignment required settings"). Live result: an unassigned Global Administrator got in and became observer. The only Entra control that holds a Global Administrator is a Conditional Access policy, which was built, tested, and then removed at my request.
- Okta's documentation describes "403 App Not Assigned" for an unassigned user, and a support article indicates super admins are not exempt. **Not verified:** that this holds for every flow (documented for the service-initiated flow) and for a free org. **Step 5 tests it** before anything else is built on it.

Everything Entra-side was destroyed on 2026-10-03 (all nine Terraform resources, plus the three soft-deleted objects purged from the Entra recycle bin). The Conditional Access policy was removed earlier the same day. **My Entra group membership is never to be changed by this project** — and the same rule carries over: **group membership at the IdP is never managed by Terraform.**

**Files** (new directory `okta/`, its own Terraform root and state key `fleet-homelab/okta.tfstate` in the same S3 bucket):
- `okta/providers.tf`, `backend.tf`, `variables.tf`, `main.tf`, `outputs.tf`, `example.tfvars`; real values (`okta_org_name`, `okta_base_url`, `fleet_subdomain`) in the gitignored `okta/terraform.tfvars`.

**Applied locally, never from CI** — the identity that can change who may sign in to Fleet shouldn't sit in the AWS pipeline's reach. **Authentication (researched 2026-10-03):**
- **API tokens (SSWS), as first assumed, are a poor fit:** per Okta's token page, a token "is valid for 30 days and automatically renew[s] every time [it's] used", and "when a token has been inactive for more than 30 days, it's revoked and can't be used again". Terraform here runs rarely, so a token would routinely be revoked between runs. Okta's own Terraform guide also says tokens "can weaken your organization's security". Any super admin can create one (Security → API → Tokens); no edition restriction appears in the pages I read.
- **Chosen (2026-10-03, at my request): an OAuth 2.0 service app** (Applications → Create App Integration → API Services; client-credentials flow with a key pair; Okta's own recommendation for Terraform). It needs an admin role assigned to the service app (Organization Administrator or Super Admin) and Okta scopes matching what Terraform manages (for example `okta.groups.manage`, `okta.apps.manage`; exact scopes to be checked at build). **This is still a static credential** (a private key file), not federation like the AWS side's GitHub OIDC; it is better than a token because it is scoped to named permissions, is revocable by deleting the app's key, and does not lapse from inactivity. True keyless federation would need Terraform to run somewhere that can present an identity to Okta, which a local run can't. The private key is shown **once**; keep it out of the repo and out of shell history (a file outside the repo, read via the provider's `private_key_path`-style argument, to be checked against the provider docs). Key format is documented inconsistently (PKCS#1 `BEGIN RSA PRIVATE KEY` in Okta's guide, PKCS#8 in other results): test at build time.
- **Unconfirmed until the org exists:** that the Free Plan org offers the "API Services" app type and lets you create a token. Okta's Terraform guide names the *Integrator Free Plan* org as its prerequisite, and I found no document that states the Workforce Free Plan has or lacks either. Step 1 checks both in the console. The fallback if neither exists is the by-hand build described in Step 1.

**Org type: decided 2026-10-03 — the Okta Workforce Identity free trial, which converts to a Free Plan.** Options researched:
- **Integrator Free Plan: rejected.** Okta's own support page says it is "not intended for production deployment" and the developer terms limit use to developing and testing an integration; real SSO for Fleet is outside that. (It would work technically; the risk is Okta ending the org without recourse.)
- **Paid Starter: rejected.** $6/user/month with a $1,500 annual minimum, billed annually (about $125/month), against a $12–15/month budget.
- **Workforce free trial → Free Plan: chosen.** From Okta's "Additional Free Trial Terms for the Workforce Identity Cloud Free Trial" (Rev 09/23/2024, read first-hand): up to **10 users**; a **30-day** trial with everything on, then the org **automatically converts to a Free Plan** with Single Sign-On, Universal Directory, adaptive MFA, API Access Management and 5 Workflows (Lifecycle Management and Device Access drop away); **no support**; the service can end on **45 days of inactivity** (so sign in to the Okta admin console at least monthly; "inactivity" is not defined, so this is an assumption); and on Okta terminating the free-trial service under MSA Section 12.9. Sign-up needs a work email, name, phone and country.
- **Not verified, check before relying on it:** Okta lists newer "Free Trial Service-Specific Terms" dated 2026-04-20 at okta.com/agreements (the PDF link returned 404 when fetched), and I did not read MSA Section 12.9. Read both. Also unverified: that the Free Plan lets you create a custom SAML app and an API token. **After day 30, confirm the org shows as Free Plan and the SAML app still works.** If Okta ever ends the org, the SSO config is Terraform, so rebuilding in a new org is quick.

**What it creates** (names of Okta Terraform provider resources to be checked against the installed provider's schemas when built, as Task 10 did for `azuread`):
- A **SAML 2.0 app integration** ("Fleet"): audience / Entity ID `https://<fleet_subdomain>`, single sign-on URL `https://<fleet_subdomain>/api/v1/fleet/sso/callback`, **application username = the user's email**, NameID format email address (Fleet uses the NameID *value* as the email and ignores the format).
- Two groups, **"Fleet Admins"** and **"Fleet Observers"**, both assigned to the app. **Membership is set by hand in the Okta console**, never in Terraform. **No direct user-to-app assignments**: a directly assigned person is in neither group, so they would arrive with no role and Fleet would make them an observer.
- Attribute statements: `FLEET_JIT_USER_ROLE_GLOBAL` as an expression, `admin` if the user is in Fleet Admins, otherwise `observer` if in Fleet Observers, otherwise the deliberately invalid value `unassigned` (`isMemberOfGroupName("Fleet Admins") ? "admin" : (isMemberOfGroupName("Fleet Observers") ? "observer" : "unassigned")`); and `name` = the user's display name, which Fleet reads for the account's name. **Expression syntax unverified**, and Okta's attribute statements are plain name/value pairs, so a person in both groups gets a deterministic `admin` (admin wins) instead of Fleet's "last value" ambiguity. Step 4 previews the real assertion.

**Built 2026-10-04 (first apply of `okta/`), what the first run taught:**
- **The service app needed the Super Administrator role, not just Organization Administrator.** With `okta.groups.manage` and `okta.apps.manage` granted and Organization Administrator assigned, group creation worked but `POST /api/v1/apps` returned 403 E0000006 ("You do not have permission to perform the requested action"). Okta's role comparison says Organization Administrator can "add and configure applications", so the cause is unexplained; switching the role to Super Administrator made it succeed. Not tested: whether a narrower custom role would also work.
- **Okta's classic path was needed for the service app.** This org's default **Create App Integration** opens the newer integration-builder wizard (labels, scopes); the plain **API Services** app is under **Classic experience**. Okta's guide describes the wizard as the default for Integrator Free Plan orgs, so confirm the org's plan label (still open).
- **Config settings and credentials moved to `okta/terraform.tfvars`** (gitignored): org name, client ID, key ID and the key's PATH. The private key itself lives in `~/.okta/terraform.key` (mode 600, outside the repo) and must not be deleted: Okta shows a key once. The provider token is `DPoP` type, valid one hour, fetched on each run.
- **`authn_context_class_ref` is mandatory** for a custom SAML app (the first create failed without it); set to `urn:oasis:names:tc:SAML:2.0:ac:classes:PasswordProtectedTransport`.
- **The provider's `metadata_url` is the wrong URL for Fleet.** It is the management-API URL (`/api/v1/apps/<id>/sso/saml/metadata`) and answers 403 to an anonymous fetch. The public URL is `https://<org>.okta.com/app/<entity_key>/sso/saml/metadata`; the output builds that and it was verified to serve HTTP 200 with a signing certificate, the email NameID format and both bindings. Copy it with `terraform output -raw metadata_url | pbcopy`.
- Result: 4 resources (two groups, the SAML app, the group assignments), re-plan clean. **Not yet verified:** the role expression, the unassigned-super-admin test (Step 5), and the Fleet login.

**IdP logo for Fleet's login button (2026-10-04).** Fleet's SSO settings have an `idp_image_url` field ("a link to a logo or other image that is used for UX", `server/fleet/app.go`); an earlier statement here that Fleet shows no IdP logo was wrong. The visitor's browser loads it before login, so it must be publicly readable. `idp_logo.tf` (AWS root, persistent, outside the teardown targets) creates a dedicated tiny bucket `fleet-homelab-idp-logo-<account>` with only the two "public policy" Block Public Access settings relaxed and one bucket-policy statement allowing `s3:GetObject` on the single key `idp-logo.png` (no ACLs, no listing, no writes). The image is **not** in the repo (Okta's brand asset, public repo); it was uploaded by hand with the standard tags (`aws s3api put-object ... --tagging "Project=fleet-lab&ManagedBy=manual"`, command in the file's header). Verified from outside: anonymous GET of the logo returns 200 `image/png`, while a list, a read of any other key and a write all return 403. The account has no account-level Block Public Access configured, which this relies on. The URL is the `idp_logo_url` output; paste it into Fleet's "IdP image URL".

**Result of the deciding test (2026-10-04):** with the Okta super admin in neither Fleet group, signing in to Fleet through Okta was refused, and SSO login worked for an assigned user. This closes the gap that Entra could not: an unassigned Global Administrator got in and became observer there. Okta enforces app assignment even for the org's super admin. **Also the same day:** moving the account from Fleet Admins to Fleet Observers and logging in again correctly changed the Fleet role to observer, so the role expression emits both `admin` and `observer` as intended and Fleet applies the demotion (an explicit value arrives, unlike Entra where a missing value left the old role in place). **Not yet checked:** the exact refusal text and Okta system-log entry; Okta's "Preview the SAML Assertion" output; the case where a user is directly assigned to the app (should never be done); and that a user who is in a group but whose Fleet account was deleted is recreated correctly.

**Direct assignment orphaned the old role; fixed with an invalid fallback value (2026-10-04).** Assigning the Fleet app to a user directly (no group) left their previous Fleet role in place. Cause, from `parseRole` in `server/fleet/sessions.go` (v4.92.0): an empty, whitespace-only or missing `FLEET_JIT_USER_ROLE_GLOBAL` is coerced to `null` and ignored, so an existing user keeps their role and a new one becomes observer; but any value other than `admin`, `maintainer`, `observer`, `observer_plus`, `technician` or `null` returns `invalid role: <value>` and the login is rejected for new and existing users alike. The expression's fallback was therefore changed from `""` to `"unassigned"`, so a user who matches neither group now fails at Fleet with an explicit error instead of silently keeping or getting a role. Applied (one in-place change, re-plan clean). **Tested the same day:** with the app assigned directly and no group, the Fleet login failed with an SSO error, as expected (whether an existing account's role stayed untouched was not separately checked). This does not end open Fleet sessions or touch existing accounts.

**Where to see the role attribute in Okta's console (2026-10-04):** Applications → Applications → Fleet → the SAML settings page's **legacy configuration** section → **Attribute Statements**. The Terraform resource (`okta_app_saml`) creates Okta's classic SAML app, which this org's newer console files under "legacy configuration". The attribute name `FLEET_JIT_USER_ROLE_GLOBAL` is Fleet's (`server/fleet/sessions.go`); Okta only supplies the value, via the expression. These are plain Attribute Statements, not Group Attribute Statements (a separate list on the same page). Terraform owns the setting: an edit in the console is reverted by the next `terraform apply` in `okta/`.

**Task 10 Step 4 closed (2026-10-05):** Okta's "Preview the SAML Assertion" was run and showed the expected attributes (the role and name values), complementing my check that the public metadata serves a signing certificate, the email NameID format and both bindings. Housekeeping done the same day: the stale `fleet-homelab/entra.tfstate` object (0 resources, 0 outputs, bucket versioned so the delete is recoverable) was removed from the state bucket, and a calendar reminder was added to sign in to the Okta admin console (the 45-day inactivity rule).

**Facts about Fleet that still hold** (read from source, v4.92.0): identity is `NameID.Value`; the role attribute is a list and `parseRole` takes the **last** value; a **new** user with no role becomes observer; an **existing** user with no role arriving is left **unchanged**; name, email and job title are written once at creation; deleting a user is blocked only for the last global admin.

**Residual gaps** (not closed by Okta):
- Removing someone from a group does **not** demote or delete their Fleet account, and an open Fleet session lives for Fleet's session duration (default 5 days, `session.duration`). Okta stops them from signing in again; it does not reach into Fleet. Offboarding = remove at the IdP **and** delete the Fleet account.
- Demotion works only by sending a different role value (move the person from Fleet Admins to Fleet Observers), never by omitting one.
- A second Fleet account appears if a user's email changes (details below).

**Steps:**

- [x] **Step 1: Sign up for the Okta Workforce Identity free trial** at okta.com/free-trial (interactive — do it yourself; use an address on your own domain). Read the 2026 free-trial terms and MSA Section 12.9 at okta.com/agreements first (see above). Record the org URL (not committed). In the admin console confirm three things on day one, before building anything: the org's plan/trial status, that a **custom SAML 2.0 app** can be created (Applications → Create App Integration → SAML 2.0), and whether an **API Services (OAuth) app** can be created for Terraform (Applications → Create App Integration → API Services) and, as a fallback, an API token (Security → API → Tokens). If neither: build the app by hand in the console and record the settings here. Put a monthly reminder in your calendar to sign in to the Okta admin console (45-day inactivity rule).
- [x] **Step 2: Remove the Entra remnants from the repo** (the `entra/` directory and any `FLEET_ENTRA_METADATA_URL` references), and delete the stale `fleet-homelab/entra.tfstate` object from the state bucket once you are sure nothing reads it.
- [x] **Step 3: Write `okta/` and apply** from `okta/` (init, plan, review, apply). Expect the app, two groups and two group assignments. Create the two groups' memberships by hand in the console.
- [x] **Step 4: Verify in Okta and with a real assertion.** Use Okta's own "Preview the SAML Assertion" on the app's SAML settings (**existence of that feature in this org is unverified**) for a user in each group, then confirm the metadata URL serves signing keys. Check: NameID is the email, audience equals the Entity ID, `FLEET_JIT_USER_ROLE_GLOBAL` is `admin` or `observer` as expected, display name is present.
- [x] **Step 5: The test that decides this whole task: an unassigned person must be refused, and that person should be a super admin.** Sign in as the org's super admin while in **neither** Fleet group and open the Fleet login. Expected: Okta refuses ("not assigned"), and no Fleet account is created. Check Settings → Users in Fleet afterwards. If a super admin gets through, stop: Okta has the same gap and the plan needs another control (a Fleet-side reconciler or turning JIT off with pre-created accounts).
- [x] **Step 6: Configure Fleet by hand once** (Settings → Integrations → Authentication → Fleet users): Entity ID, the app's metadata URL, provider name "Okta", single sign-on on, **"Create user and sync permissions on login" on**, "Allow SSO login initiated by identity provider" **off** (Fleet's own Okta guide turns it on for the dashboard-tile experience; off removes the request-binding weakness, and the Okta tile then needs a service-initiated start). Log in from Fleet's own page and confirm the role in Settings → Users.
- [x] **Step 7: Commit** `okta/*.tf`, `okta/example.tfvars` and `okta/.terraform.lock.hcl` (never `okta/terraform.tfvars` or any token). Run the public-readiness check first.

**Those settings live only in the database** (they survive teardowns through the Aurora snapshot). Task 11's `default.yml` must carry the same values, or its first run can clear them; Task 11 Step 8 repeats the login after GitOps takes ownership.


**What an SSO login does and does not sync** (read from `ee/server/service/users.go`, not documented anywhere I found): for an **existing** user, each login syncs only the **role and team memberships**, and only when the assertion carries a role value. Name, email and job title (`position`) are written **once, at creation**, and a SAML attribute never sets `position` at all (the creation payload is name, email, SSO flag, role, teams). The consequences:
- **Display-name change** (same email): Fleet keeps the old name until someone edits it or deletes the user so the next login recreates it.
- **Email/UPN change** (a marriage, a domain move): the NameID is the lookup key, so Fleet treats the new address as a new person and creates a **second** account with the role from the claim. The old account stays, with its role, tokens and audit history, and nothing removes it — SCIM deprovisioning only fires when a user is deleted or deactivated in the IdP, not renamed. After an email change, delete the old Fleet account by hand. (Keeping the old address as an alias at the IdP doesn't help if the NameID is the primary address; Okta's username/email behavior here is unverified.)
- **The impact of that second account** (verified in source and schema; `GetSSOUser` is `UserByEmail(NameID)`): an admin account is the same kind of record as any other user — the role is just a field (`global_role`, plus per-fleet roles), set from the claim — so a renamed *observer* gets a second *observer* account by exactly the same mechanism. The person still logs in and gets the same role, because a rename doesn't change their IdP group membership (with no role claim they would get the default **observer**). What follows: the old account stays, still SSO-enabled with its role, reachable only by someone presenting that exact NameID (so it matters if the address is ever reused, and Fleet never flags it as orphaned); the audit trail splits across two identities; queries, policies and labels the old account authored keep it as author, but **deleting it sets their author link to NULL** (`ON DELETE SET NULL`), and past script runs and software installs lose their user link the same way; on deletion Fleet first copies the user's id, name and email into a `users_deleted` table "for audit/activity purposes" (which views read it was not traced). Fleet refuses to delete the *last* global admin, so cleanup is safe once the new account exists. An SSO login whose email matches an existing **non-SSO** account is refused outright (`ssoAccountDisabled`) — one more reason the break-glass address must never equal anyone's the IdP email. A detective control for later: Fleet logs a `user added by SSO` activity whenever login creates an account, which Task 19's activities webhook can turn into an alert. To avoid the duplicate in the first place, keep the user's primary `mail` (the NameID source) stable through a rename and add the new address as an alias — unverified for any particular mail setup.
- **Job title** is only ever typed into Fleet (account page) or set through the API; mapping a claim would be ignored.
- **Demotion** only works by sending a different role value (see the explicit `observer` value above), never by omitting one.

---

### Task 11: Fleet GitOps repository

**Workflow additions (2026-10-06):** (1) a first step checks Fleet's `/healthz`: a **scheduled** run skips cleanly with a notice when the stack is torn down, while a push, pull request or manual run fails with "bring the stack up" (tested locally in all four cases, then live); (2) the health check, the action's version lookup and every `fleetctl` request send the `x-fleet-ci` header from the `FLEET_CI_HEADER` secret (`fleetctl config set --custom-header`), so runners outside the US get past the WAF (Task 4); (3) the action's `fleetctl config set` now reads the URL and token from the environment instead of interpolating them into the script. The infra repo's `up.sh` starts a run after each rebuild (Task 14).

Requires the break-glass admin from Task 3 Step 8 (used below to create the API-only user). Layout verified against the templates `fleetctl new` ships in Fleet v4.92.0 (an earlier draft used the pre-4.7x `teams/` directory and a single top-level `default.yml` with `policies:`/`queries:` keys — neither matches the current scaffold).

**This second repo is public too** (same portfolio reasoning as the infra repo), and it is locked down the same way (Task 15 Step 5). It is the higher-stakes of the two: its CI holds a Fleet API token with the `gitops` role, which can change Fleet's configuration — including scripts and software that run on every enrolled device. So the model is: **no secret value is ever written into a file** (every secret is a `$VARIABLE` that the workflow fills in from GitHub Actions secrets); only you can push or merge; fork PRs get no secrets and their workflows wait for your approval; and the apply job runs only on `main`. Step 5 has a pre-publish review before the first push, because history can't be un-published.

**Files (new repo, `fleet-homelab-gitops`, not this one) — all created by the scaffold, then edited:**
- Modify: `default.yml` (repo root — the scaffold puts it at the root, not under a subdirectory)
- Modify: `fleets/workstations.yml` (the scaffold's directory is `fleets/`, formerly `teams/`)
- Modify: `.github/workflows/workflow.yml` (env block)

- [x] **Step 1: 🎓 You run this — scaffold the repo.** *(Pre-flight: `fleetctl --version` → 4.92.x. The server image is v4.92.0; a patch-level difference (the installed fleetctl is 4.92.2) is accepted, any other minor version: stop. See Task 3 Step 8a.)* `fleetctl new` writes a starter GitOps repository (YAML for org settings, fleets, policies, labels, plus the GitHub Actions workflow). Read the generated files before editing them — they are the best documentation of what Fleet can manage from Git.

```bash
mkdir -p ~/Dev/fleet-homelab-gitops && cd ~/Dev/fleet-homelab-gitops   # ~/Dev, not ~/Documents: iCloud corrupts git repos and .terraform caches
git init -q -b main
git config user.name "Chris Durham"
git config user.email "<id>+<login>@users.noreply.github.com"   # the GitHub noreply address; commits are GPG-signed (global commit.gpgsign) and that address is a UID on the key
fleetctl new --org-name "Homelab" --dir . --force
rm fleets/personal-mobile-devices.yml   # not needed for this homelab (no BYOD mobile fleet)
```

`fleetctl new` is non-interactive in v4.92.0 (flags above; `--force` because the directory already exists). It generates `default.yml`, `fleets/workstations.yml` and `fleets/personal-mobile-devices.yml`, `labels/`, `platforms/` (configuration profiles), `.github/workflows/workflow.yml`, and `.github/fleet-gitops/` (the action that runs `fleetctl gitops`). Every `fleets/*.yml` file is applied automatically, and — because `default.yml` contains `org_settings:` — any Fleet in your instance that has *no* matching file is deleted (`--delete-other-fleets`). That is the desired GitOps behavior, but means fleets created in the UI won't survive the next run.

**Done 2026-10-05 (Steps 1-8).** Step 8: after the first GitOps apply, signing in through Okta gave the admin role. Step 9 is split: Task 9 (break-glass MFA) is done; Task 8 Part B (Apple push certificate) is still open and optional. The GitOps repo is public at `chrsdrhm/fleet-homelab-gitops` (one signed commit). What happened, beyond the notes above:
- **Handling the API token:** run any command that prints a secret in a separate terminal, never with Claude Code's `!` prefix (its output lands in the chat session). Capture the output to a private file (`umask 077`), pipe it straight into `gh secret set`, then delete the file. Do not keep it in a password manager or paste it into a chat.
- **Secrets set (four):** `FLEET_URL`, `FLEET_API_TOKEN`, `FLEET_OKTA_METADATA_URL`, `FLEET_IDP_IMAGE_URL`, each piped straight from its source.
- **Lockdown applied and read back** before the first push: fork-PR approval for all external contributors, read-only workflow token, GitHub-owned actions only with SHA pinning required, secret scanning and push protection, Dependabot alerts, private vulnerability reporting, wiki and projects off, you the only collaborator. After the first push, the `protect-main` ruleset (no deletion, no force-push, PR required, `fleet-gitops` check required, admin bypass).
- **First run: success** (dry run then real apply). The public Actions log was scanned for the hostname, logo URL, account ID, Okta org and token fragments: no hits (secrets show as `***`). Afterwards an unauthenticated SSO initiation against Fleet still returned a SAML request pointing at Okta, so the apply did not clear SSO.
- **Not read back from Fleet:** the local `fleetctl` session token had expired by then, so the live fleets, labels and policy were not re-listed; the run log says it applied 1 fleet, 1 policy and the fleet config. Refresh with an SSO API token to inspect.
- **Recreating a repo resets its settings to GitHub defaults.** After any delete-and-recreate, re-apply the Task 15 Step 5 protections (fork-PR approval, read-only workflow token, Actions allow-list with SHA pinning, secret scanning and push protection, Dependabot alerts, private vulnerability reporting) and the `protect-main` ruleset, then read each back.

**Progress 2026-10-04 (the repo exists locally at `~/Dev/fleet-homelab-gitops`; not yet committed or published).** Step 1 (scaffold) done. Steps 2 and 3 done with these deviations from the text below, all found by reading the scaffold and running a local dry run against the live Fleet:
- **No enroll secrets in Git.** Fleet's `gitops.exceptions.secrets` is `true` by default and `fleetctl gitops` rejects a `secrets:` key then. So no `FLEET_GLOBAL_ENROLL_SECRET` / `FLEET_WORKSTATIONS_ENROLL_SECRET` secrets either; only `FLEET_URL`, `FLEET_API_TOKEN`, `FLEET_OKTA_METADATA_URL` and `FLEET_IDP_IMAGE_URL` go in GitHub. Other exceptions at that moment: labels `false`, software `false`; `gitops_mode_enabled` is `false`.
- `enable_sso_idp_login: false` (Task 10's decision), `idp_image_url` added, `actions/checkout` pinned to a commit SHA (`# v6`), the unused `.gitlab-ci.yml` removed, and README, MIT LICENSE and `.github/CODEOWNERS` added.
- **Local `fleetctl` auth** for this task is an SSO admin's API token (`fleetctl config set --address ... --token "$(pbpaste)"`), because the break-glass account has MFA. `fleetctl api` needs the `/api` prefix (`fleetctl api /api/latest/fleet/me`; without it, 404). `fleetctl` is 4.92.2 against server 4.92.0: it warns "Version mismatch" on every call and still works.
- **Dry run** (`FLEET_URL=... FLEET_OKTA_METADATA_URL=... fleetctl gitops -f default.yml -f fleets/workstations.yml --delete-other-fleets --dry-run`, exit 0): would update 4 labels, apply the fleet config, apply 1 fleet and 1 policy, **delete the `📱🔐 Personal mobile devices` fleet** (0 hosts), and apply no scripts, software or profiles. Fleet had 0 hosts and two users (the MFA break-glass admin and the SSO admin). Glob warnings ("matched no ... files") are expected for the empty folders.
- **Pre-publish review passed:** `platforms/` and `labels/` are the generic scaffold; no `pull_request_target`; permissions `contents: read`; the only literals are public (the Fleet URL, the Okta Entity ID, the logo URL). Noted, not changed: the scaffold action runs `npm install -g fleetctl@<server version>` and falls back to `fleetctl@latest` if that fails.
- **Nothing identifying goes in the public repos** (see Global Constraints). In this repo that means the YAML uses variables: `entity_id: "$FLEET_URL"` and `idp_image_url: "$FLEET_IDP_IMAGE_URL"`, both repository secrets. Limits to know: the hostname is still discoverable through Certificate Transparency logs and public DNS, and GitHub masks secret values in public Actions logs but does not guarantee every error message is clean.
- **Before the first push:** `gh auth refresh -h github.com -s workflow` (the token lacks the `workflow` scope GitHub requires to push workflow files). Set the three GitHub secrets **before** the push that triggers the apply, or the first run fails on an empty token (a safe failure, but noisy).

- [x] **Step 2: Edit `default.yml`.** The scaffold already has `org_settings.org_info.org_name` (set by `--org-name`) and `server_settings.server_url: $FLEET_URL`. Add to `org_settings:` (uncommenting/replacing the scaffold's commented `sso_settings` example, and adding `secrets`):

```yaml
org_settings:
  # ...org_info and server_settings from the scaffold stay as they are...
  sso_settings:
    enable_sso: true
    enable_sso_idp_login: false     # Task 10: left OFF on purpose; GitOps must not turn it on (it removes the login request-binding)
    enable_jit_provisioning: true   # Premium
    idp_name: "Okta"
    idp_image_url: "$FLEET_IDP_IMAGE_URL"   # NOT a literal (it embeds the AWS account ID): the `idp_logo_url` output from the infra repo, held as a repository secret
    entity_id: "$FLEET_URL"                  # NOT a literal: the Fleet hostname is kept out of both public repos. Must equal the Okta app's audience exactly (no trailing slash)
    metadata_url: "$FLEET_OKTA_METADATA_URL"
  # No `secrets:` key. Fleet's change-management settings exclude enroll secrets from
  # GitOps by default (`gitops.exceptions.secrets: true`), and a `secrets:` key then
  # makes `fleetctl gitops` fail: 'Error: "secrets" is excepted from GitOps management'
  # (found by the local dry run, 2026-10-04). Enroll secrets are managed in Fleet itself.
```

And under `controls:` (the scaffold has this commented out) turn on Windows MDM — this is the switch that makes use of the WSTEP secret from Task 8:

```yaml
controls:
  windows_enabled_and_configured: true
```

(**Task 19, if built after this**: also add `webhook_settings.activities_webhook` here — see that task's Step 5 for the exact block and its caveat about GitOps reconciliation.) Leave the rest of the scaffold as generated (do not add empty placeholder `policies:`/`queries:`/`agent_options:` keys as an earlier draft did — the current scaffold doesn't use them, and in GitOps YAML an explicitly empty section is treated as "manage this as empty", which is not what you want). `enable_jit_provisioning` is a Premium feature — accounts are created automatically on first SSO login; the role each account gets comes from the `FLEET_JIT_USER_ROLE_GLOBAL` attribute built in Task 10 (an Okta expression over the Fleet Admins and Fleet Observers groups; a user in neither gets the invalid value `unassigned`, so Fleet rejects the login instead of guessing a role). Apple MDM is *not* configured here — it's connected through the UI in Task 8 Part B.

- [x] **Step 3: Edit `fleets/workstations.yml`** — the scaffold already names it "💻 Workstations". Add a top-level `settings:` block for this fleet's enroll secret (per-fleet secrets live under `settings:`, the equivalent of `org_settings:` in `default.yml`; verified in Fleet's yaml-files docs):

```yaml
name: "💻 Workstations"
# ...controls/reports/policies/software from the scaffold stay as they are. No `settings.secrets`
# (see Step 2): enroll secrets are managed in Fleet, not Git.
```

(Verify the scaffold's default `controls:` for this fleet are what you want before pushing — macOS setup-assistant lines are commented out by default, so nothing will require Apple MDM.)

- [x] **Step 4: 🎓 You run this — create the GitOps API-only user on Fleet** (what it does: creates a user that has an API token but no password or UI login, with the `gitops` role, which can only apply configuration) **Authenticating `fleetctl` for this:** the break-glass account now has email MFA (Task 9), and Fleet rejects `fleetctl login` for MFA users, so use an SSO admin's API token instead: sign in to Fleet through Okta, My account → Get API token, then `fleetctl config set --address https://<fleet_subdomain> --token <token>` (do not type the token on a shared screen; it is a session-bound credential for your own account and can be revoked from the same page).

```bash
fleetctl user create --name "GitOps CI" --global-role gitops --api-only
```

Verified in Fleet v4.92.0: `--api-only` needs no email/password/`--username` (there is no `--username` flag; an earlier draft used one and would have failed), and **prints the API token once** — press a key when prompted and copy it immediately into your password manager. The `gitops` role is only valid for API-only users. Do not use `fleetctl login` here: that would need a password user and produces a short-lived session token (default 5 days) that would silently break the workflow.

- [x] **Step 5: Public-readiness gate, then publish the repo as PUBLIC and lock it down.** `gh` must be logged in (`gh auth status`) **and its token needs the `workflow` scope** to push `.github/workflows/*` (GitHub refuses workflow-file pushes from a token without it); the current token has `admin:gpg_key, gist, read:org, repo` only, so run `gh auth refresh -h github.com -s workflow` first (interactive, browser). **Creating a public repo is effectively irreversible — confirm immediately before the `gh repo create`.**

**Review before the first commit** (this is the part that is specific to a GitOps repo):
1. **`platforms/` configuration profiles.** Read every file. Profiles can embed Wi-Fi passwords, certificates, or server addresses. Delete or genericise anything that isn't safe to publish (the scaffold's defaults are generic, but check).
2. **No literal secrets, IDs or addresses.** Every value that isn't public must be a `$VARIABLE` (enroll secrets, `$FLEET_OKTA_METADATA_URL` — that URL embeds your Okta org name and app entity key). `git grep -niE 'secret|token|password|okta\.com|0oa[0-9a-z]{10}|trial-[0-9]+'` and read each hit; also the email/secret scans from Task 15 Step 1's gate.
3. **Workflow triggers.** Open `.github/workflows/workflow.yml`. It must **not** use `pull_request_target` (that trigger runs with secrets against untrusted code). The apply job must run only on `push` to `main`, `schedule` and `workflow_dispatch`; `pull_request` may dry-run (fork PRs simply get no secrets, so their dry-run fails harmlessly).
4. **Pin every `uses:` to a full commit SHA** (with the version as a trailing comment). Step 5's settings turn on `sha_pinning_required`, and an unpinned action fails the run. Note which actions the scaffold uses (`actions/checkout`, plus its local `.github/fleet-gitops/` action) and allow-list only those.
5. **Add `README.md`** (what it is and that it's a homelab/learning repo, LinkedIn badge like the infra repo's, AI-assistance note), an **MIT `LICENSE`**, and `.github/CODEOWNERS` (`* @<owner>`).

```bash
git add -A && git commit -m "Initial Fleet GitOps config"
git log --format='%ae %G?'                      # noreply address, signature G
gh repo create fleet-homelab-gitops --public --source=. --push --description "Fleet GitOps configuration for a homelab (Okta SSO, policies, MDM)"
```

**Then lock it down immediately** — the same calls as Task 15 Step 5 (use that block, with `R=repos/<owner>/fleet-homelab-gitops`): fork-PR approval for all outside contributors, read-only workflow token, selected actions only (adjust `patterns_allowed` to the actions the scaffold actually uses — it needs no `aws-actions/*` or `hashicorp/*`) with SHA pinning, secret scanning + push protection, Dependabot alerts, private vulnerability reporting, wiki/projects off, and the `protect-main` ruleset. Add the dry-run job as a required status check on the ruleset once it has run once. Confirm the only collaborator is you and that both commits report `verified=true` (`gh api repos/<owner>/fleet-homelab-gitops/commits/<sha> --jq .commit.verification`).

- [x] **Step 6: Add GitHub Actions secrets, and expose them to the workflow.** The scaffolded workflow only passes `FLEET_URL` and `FLEET_API_TOKEN` to the gitops step — the extra variable used in the YAML above would expand to an empty string unless you add them to that step's `env:` block in `.github/workflows/workflow.yml`:

```yaml
        env:
          FLEET_URL: ${{ secrets.FLEET_URL && secrets.FLEET_URL || 'https://fleet.example.com' }}
          FLEET_API_TOKEN: ${{ secrets.FLEET_API_TOKEN }}
          # added:
          FLEET_OKTA_METADATA_URL: ${{ secrets.FLEET_OKTA_METADATA_URL }}
          FLEET_IDP_IMAGE_URL: ${{ secrets.FLEET_IDP_IMAGE_URL }}
```

```bash
gh secret set FLEET_URL --body "https://<fleet_subdomain>"
gh secret set FLEET_API_TOKEN            # prompts — paste the token from Step 4; never put it on the command line or in history
gh secret set FLEET_IDP_IMAGE_URL       # prompts — paste `terraform output -raw idp_logo_url` from the infra repo (root, not okta/); it embeds the AWS account ID
gh secret set FLEET_OKTA_METADATA_URL   # prompts — paste the Okta app's metadata URL (Task 10; it contains the org and app IDs, so keep it out of files)
git add -A && git commit -m "Pass extra secrets to gitops step" && git push
```

- [x] **Step 7: Run the workflow manually and verify**

Run: `gh workflow run "Apply latest configuration to Fleet" && gh run watch`
Expected: workflow completes successfully (the scaffold also dry-runs on pull requests, applies on push to `main`, and reconciles nightly); in the Fleet UI, Settings > Organization settings shows "Homelab", Settings > Integrations > SSO shows Okta configured, and Settings > Integrations > MDM shows Windows MDM turned on.

- [x] **Step 8: Verify SSO login works** (already proven once through the UI in Task 10; this repeats it after GitOps takes ownership of the settings, which is where a mismatch would clear them) by logging out of the break-glass session and signing in via the Okta SSO button at `https://<fleet_subdomain>/login`. Then confirm the new user's role in Settings > Users is `admin` (if it isn't, check Task 10's assertion preview first: the attribute name and value Okta emits are the prime suspects, and the user must be in the group that maps to that role).

- [ ] **Step 9: Go back and do Task 9** (break-glass MFA hardening) now that SSO is proven as a second way in. Also do the Apple MDM half of Task 8 (Part B) at this point if you didn't already — it is best done once you have an SSO/domain-email user, because of the APNs CSR email-domain restriction described there.

Note for later: because the Aurora snapshot/restore mechanism preserves the database, and this GitOps repo's own state lives in GitHub (not AWS), none of this Task needs repeating after a `down`/`up` cycle — only the nightly cron or a manual `gh workflow run` needs to happen if you want to force a reconciliation after a rebuild.

---

### Task 12: Osquery log destination — Firehose → S3

**Files:**
- Create: `logging.tf`
- Modify: `fleet.tf` (merge the addon's outputs into `fleet_config`)

**Interfaces:**
- Produces: `module.firehose-logging.fleet_extra_environment_variables`, `module.firehose-logging.fleet_extra_iam_policies` — consumed by the `fleet.tf` edit in Step 4 below.

- [ ] **Step 1: Write `logging.tf`**

```hcl
module "firehose-logging" {
  source = "github.com/fleetdm/fleet-terraform//addons/logging-destination-firehose?depth=1&ref=tf-mod-addon-logging-destination-firehose-v1.3.0"

  prefix = "fleet-homelab-"

  osquery_results_s3_bucket = {
    name         = "fleet-homelab-osquery-results"
    expires_days = 30
  }

  osquery_status_s3_bucket = {
    name         = "fleet-homelab-osquery-status"
    expires_days = 30
  }

  audit_s3_bucket = {
    name         = "fleet-homelab-audit"
    expires_days = 30
  }
}
```

- [ ] **Step 2: Init, validate, and plan**

Run: `terraform init && terraform fmt && terraform validate && terraform plan -var-file=terraform.tfvars -out=tfplan`
Expected: plan shows 3 S3 buckets, 3 Firehose delivery streams, 3 IAM roles/policies — 30-day lifecycle expiration on each bucket.

- [ ] **Step 3: Apply**

Run: `terraform apply tfplan`

- [ ] **Step 4: Wire the addon's outputs into `fleet.tf`, on top of Task 6's SES merge** (don't drop it — extend it):

```hcl
    extra_environment_variables = merge(
      {
        FLEET_LICENSE_KEY          = var.fleet_license_key
        FLEET_LOGGING_JSON         = "true"
        FLEET_MYSQL_MAX_OPEN_CONNS = "10"
        FLEET_REDIS_MAX_OPEN_CONNS = "50"
      },
      module.ses.fleet_extra_environment_variables,
      module.firehose-logging.fleet_extra_environment_variables
    )
    extra_iam_policies = concat(
      [aws_iam_policy.software_installers.arn],
      module.ses.fleet_extra_iam_policies,
      module.firehose-logging.fleet_extra_iam_policies
    )
```

(Keeps Task 3's `aws_iam_policy.software_installers` in the list — dropping it would cut the task's access to its installers bucket. Task 8 also merges `extra_secrets`/`extra_execution_iam_policies` into this same block; those are different keys and don't conflict.)

- [ ] **Step 5: Validate, plan, apply**

Run: `terraform fmt && terraform validate && terraform plan -var-file=terraform.tfvars -out=tfplan && terraform apply tfplan`
Expected: ECS service redeploys with the new environment variables (`FLEET_OSQUERY_STATUS_LOG_PLUGIN=firehose`, `FLEET_OSQUERY_RESULT_LOG_PLUGIN=firehose`, `FLEET_FIREHOSE_REGION`, stream names — these come from the addon's output map, not typed manually).

- [ ] **Step 6: Verify data is landing in S3**

Wait for at least one enrolled host to check in (or trigger a live query), then run:
`aws s3 ls s3://fleet-homelab-osquery-status/ --recursive | tail -5`
Expected: at least one object listed within a few minutes of a host checking in.

- [ ] **Step 7: Commit**

```bash
git add logging.tf fleet.tf .terraform.lock.hcl
git commit -m "Route osquery result/status/audit logs to S3 via Firehose"
```

---

### Task 13: AWS Budget alert

**Files:**
- Create: `budget.tf`

**Interfaces:**
- Consumes: nothing (standalone, account-level resource).

- [x] **Step 1: Write `budget.tf`**

```hcl
resource "aws_budgets_budget" "fleet_homelab" {
  name         = "fleet-homelab-monthly"
  budget_type  = "COST"
  limit_amount = "100"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = range(10, 101, 10)   # $10, $20, ... $100 of actual spend
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "ABSOLUTE_VALUE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [var.budget_alert_email]
    }
  }
}
```

**Alerts every $10, not the original 20/40/60/80/100%** — chosen so a forgotten stack is noticed sooner (a running stack costs ~$5.50/day). Ten alerts on one budget was accepted by AWS (verified by applying it; an earlier recollection of a five-per-budget limit was wrong, and the AWS quotas page lists no such limit). **Budget data only refreshes up to about three times a day, 8–12 hours apart** (AWS docs), so this is a "within about a day" alarm, not a real-time one — the real protection is still running `down.sh`. Budgets without actions are free; the "2 free" quota applies to budgets *with* actions. The account also has an older `Monthly Budget` ($1, one forecast alert), which is independent of this one and left alone.

`budget_alert_email` is a sensitive-by-privacy variable (add it to `variables.tf` as `type = string`, to `example.tfvars` as a placeholder, and to the real `terraform.tfvars`; Task 15's workflow supplies it from a `BUDGET_ALERT_EMAIL` repo secret). It stays out of Git because this repo is public.

Given the actual usage pattern (torn down most of the time, averaging ~$12–15/mo per the spec), this $100/mo target gives generous headroom — it's really a safety net against forgetting to run `down.sh`, not a tight budget line.

- [x] **Step 2: Validate and plan**

Run: `terraform fmt && terraform validate && terraform plan -var-file=terraform.tfvars -out=tfplan`
Expected: plan shows one `aws_budgets_budget` with 10 notification blocks. If the Fleet stack is torn down at this point, a bare `plan` would also rebuild it — add `-target=aws_budgets_budget.fleet_homelab` to `plan` (this was done when the task was executed while the stack was down).

- [x] **Step 3: Apply**

Run: `terraform apply tfplan`

- [x] **Step 4: Verify**

Run: `aws budgets describe-budget --account-id $(aws sts get-caller-identity --query Account --output text) --budget-name fleet-homelab-monthly --query 'Budget.{limit:BudgetLimit,notifications:NotificationsWithSubscribers[].Notification.Threshold}'`
Expected: `limit` shows `100 USD`; `notifications` lists `[10, 20, 30, 40, 50, 60, 70, 80, 90, 100]` (all `ABSOLUTE_VALUE`). Also confirm the address is subscribed: `aws budgets describe-subscribers-for-notification --account-id <acct> --budget-name fleet-homelab-monthly --notification NotificationType=ACTUAL,ComparisonOperator=GREATER_THAN,Threshold=10,ThresholdType=ABSOLUTE_VALUE`.

- [ ] **Step 5: Check the inbox once.** Whether directly-listed Budgets email recipients need a confirmation click is unclear — an independent review said no, and AWS's own docs and search results conflict on it, so this isn't asserted either way. Look in `the budget alert address` (including spam) for an "AWS Notification - Subscription Confirmation" email and click confirm if one arrives; if none does, nothing further is needed. Budgets emails also don't depend on SES or on the Fleet stack being up.

- [x] **Step 6: Commit**

```bash
git add budget.tf variables.tf example.tfvars
git commit -m "Add AWS Budget: alert every \$10 of actual spend up to \$100/mo"
```

---

### Task 14: Cost-control scripts

**Built 2026-10-06: the files in `scripts/` are the source of truth and supersede the code blocks below** (kept as the original design). Differences, all from running the routine by hand first:
- **Both:** `AWS_REGION` defaults to `us-east-1` and the pager is off.
- **`up.sh` / `down.sh`:** stop with a clear message if Terraform is not initialized (`terraform init -backend-config=backend.hcl`; the backend is a partial configuration, see Task 1).
- **`up.sh`:** after the apply it waits for the service to stabilize and reports `/healthz` and `/` status codes (200 on `/` means the data was restored; a 307 to `/setup` means an empty database). If the apply fails with `InsufficientDBInstanceCapacity`, it explains the options (retry later, `down.sh`, or another instance class of the same size) and warns not to change `azs` on a live or partial stack.
- **`up.sh` starts a GitOps run** after a healthy rebuild (`gh workflow run` in the GitOps repo), so a change pushed while the stack was down is applied straight away. Best effort: it needs the GitHub CLI logged in locally (a CI token for this repo cannot dispatch another repo's workflow); `NO_GITOPS=1` skips it. Tested: it dispatched a run that succeeded.
- **`down.sh`:** skips the snapshot if no Aurora cluster exists; tags the snapshot `ManagedBy=script`; deletes the Container Insights log group twice, 20 seconds apart (AWS re-creates it after Terraform deletes it); **prunes teardown snapshots automatically, keeping the newest `KEEP_SNAPSHOTS` (default 2)**, and only in a run that took a fresh snapshot; then **verifies** that no ECS cluster, Aurora, Redis, load balancer, NAT gateway, tagged VPC or WAF web ACL remains, exiting 2 if something does.

The usage pattern is intermittent (evenings and weekends), so the scripts are `up.sh` and `down.sh`. There is deliberately no idle/resume pair: it would pause only Fargate and Aurora compute while Redis, the ALB, WAF and the NAT Gateway keep billing.

**Files (in `fleet-homelab-infra`):**
- Create: `scripts/up.sh`
- Create: `scripts/down.sh`
- (`scripts/tf-apply.sh` already exists, written and committed in Task 3 — `up.sh` calls it, nothing to create here.)

**Interfaces:**
- Consumes: nothing beyond AWS CLI credentials and this repo's Terraform state.

- [x] **Step 1: Write `scripts/up.sh`** — finds the latest teardown snapshot dynamically via the AWS API rather than a local file. An earlier draft of this task used a gitignored `.last-rds-snapshot` file written by `down.sh` — that breaks the moment either script runs somewhere other than the same persistent local checkout (e.g. a GitHub Actions runner, which starts fresh every run with no memory of a prior one — see Task 15). Querying AWS directly for the most recent snapshot matching this project's naming convention works identically whether run locally or in CI, so there's no reason to prefer the fragile version even for local-only use.

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

SNAPSHOT_ARGS=()
if [ "${1:-}" != "--fresh" ]; then
  SNAPSHOT_ID=$(aws rds describe-db-cluster-snapshots \
    --snapshot-type manual \
    --query "sort_by(DBClusterSnapshots[?starts_with(DBClusterSnapshotIdentifier, 'fleet-homelab-teardown-')], &SnapshotCreateTime)[-1].DBClusterSnapshotIdentifier" \
    --output text)
  if [ -n "$SNAPSHOT_ID" ] && [ "$SNAPSHOT_ID" != "None" ]; then
    echo "Restoring from snapshot: $SNAPSHOT_ID (pass --fresh to skip and start empty)"
    SNAPSHOT_ARGS=(-var "rds_snapshot_identifier=$SNAPSHOT_ID")
  else
    echo "No teardown snapshot found — creating an empty database."
  fi
else
  echo "--fresh passed — creating an empty database."
fi

# ${arr[@]+"${arr[@]}"} keeps macOS bash 3.2 + `set -u` from erroring on an empty array
VAR_ARGS=(-var-file=terraform.tfvars ${SNAPSHOT_ARGS[@]+"${SNAPSHOT_ARGS[@]}"})
terraform plan -input=false "${VAR_ARGS[@]}" -out=tfplan
# tf-apply.sh (Task 3) auto-retries the one known, reproducible IAM role-propagation
# race this stack hits on every from-scratch build of module.fleet — see Task 3 for
# why a bare `terraform apply` isn't enough here.
./scripts/tf-apply.sh tfplan -- "${VAR_ARGS[@]}"
echo "Up. This can take 15-20 minutes for VPC/NAT/Aurora/ALB/ECS to fully stabilize even after apply returns."
```

- [x] **Step 2: Write `scripts/down.sh`** — snapshots Aurora before destroying it, and deliberately leaves `module.mdm`, the private-key secret, the software-installers bucket, `module.ses`, the Firehose/S3 buckets, Route 53/ACM, and the budget alert untouched. `module.fleet` now includes the VPC (it's the root module — see Task 3), so `-target=module.fleet` tears down the VPC, NAT Gateway, Aurora, Redis, ALB, and ECS together; no separate VPC target needed. The confirmation prompt is skippable via a `CONFIRM=destroy` environment variable, so the same script works unattended from Task 15's CI workflow without changing its logic.

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "This will destroy the VPC (incl. NAT Gateway), Aurora, Redis, ALB, ECS, the"
echo "WAF Web ACL, and the migrations runner, after snapshotting Aurora first."
echo "NOT destroyed: Route 53 hosted zone, ACM cert, Terraform state backend,"
echo "MDM secrets (Apple certs), the Fleet server private key, the software-"
echo "installers bucket, SES identity, Firehose/S3 log buckets, the AWS Budget"
echo "alert, and the activities-webhook Lambda/DynamoDB/API Gateway (Task 19 —"
echo "costs nothing at rest, so it isn't targeted for teardown either)."

if [ "${CONFIRM:-}" != "destroy" ]; then
  read -p "Type 'destroy' to confirm: " confirm
else
  confirm="$CONFIRM"
fi
if [ "$confirm" != "destroy" ]; then
  echo "Aborted."
  exit 1
fi

SNAPSHOT_ID="fleet-homelab-teardown-$(date +%Y%m%d%H%M%S)"
echo "Snapshotting Aurora as $SNAPSHOT_ID..."
aws rds create-db-cluster-snapshot \
  --db-cluster-identifier fleet-homelab \
  --db-cluster-snapshot-identifier "$SNAPSHOT_ID" \
  --tags Key=Project,Value=fleet-lab Key=ManagedBy,Value=terraform >/dev/null
aws rds wait db-cluster-snapshot-available --db-cluster-snapshot-identifier "$SNAPSHOT_ID"
echo "Snapshot complete: $SNAPSHOT_ID"

terraform destroy -input=false -var-file=terraform.tfvars \
  -target=aws_route53_record.fleet_alb \
  -target=aws_cloudwatch_log_group.container_insights \
  -target=module.migrations \
  -target=aws_wafv2_web_acl_association.fleet_homelab \
  -target=aws_wafv2_web_acl.fleet_homelab \
  -target=module.fleet \
  -auto-approve
# No -target=module.monitoring (Task 5 was superseded — nothing to destroy there;
# see Task 5's stub) and no -target=module.waf (Task 4 builds a plain
# aws_wafv2_web_acl directly, not a module — see Task 4's note on why).

# ECS Container Insights keeps writing metrics while the cluster shuts down, so AWS
# RE-CREATES this log group (untagged) right after Terraform deletes it. Found on the
# first real teardown. If it's left behind, the next `up` fails with
# ResourceAlreadyExistsException when Terraform tries to create it. Delete it by exact name.
aws logs delete-log-group --log-group-name /aws/ecs/containerinsights/fleet-homelab/performance 2>/dev/null || true

echo "Down. Route 53 zone, ACM cert, TF state backend, MDM secrets, private key,"
echo "installers bucket, SES, log buckets, and budget alert all remain. Run"
echo "scripts/up.sh to rebuild — it automatically finds and restores from"
echo "snapshot $SNAPSHOT_ID."
echo "Each teardown leaves a manual snapshot that bills until deleted. Prune old"
echo "ones, keeping the newest, e.g.: aws rds describe-db-cluster-snapshots"
echo "--snapshot-type manual --query 'DBClusterSnapshots[].DBClusterSnapshotIdentifier'"
echo "then aws rds delete-db-cluster-snapshot --db-cluster-snapshot-identifier <id>."
```

- [x] **Step 3: Make them executable and verify**

Run: `chmod +x scripts/*.sh && ls -l scripts/`
Expected: `up.sh`, `down.sh` and `tf-apply.sh` (from Task 3) show the executable bit set.

- [x] **Step 4: Smoke-test `down.sh` / `up.sh`** (done 2026-10-06. `down.sh` with `CONFIRM=destroy`: snapshot taken and tagged `ManagedBy=script`, 87 resources destroyed, log group cleaned up, the two newest teardown snapshots kept, its own zero-check passed and an independent AWS check agreed. `up.sh`: found and restored the newest teardown snapshot by itself, `tf-apply.sh` retried the known IAM race twice, then reported `/healthz` 200 and `/` 200; independently verified Aurora available, ECS 1/1, target healthy, SSO starting an Okta login, no drift, and the plan file removed. Note for Task 15: the raw Terraform output includes ARNs with the account ID, so CI logs must mask it.) — this is the one worth actually rehearsing, since it's the primary day-to-day pattern. Before running it, note the host count and org name in the Fleet UI so you have something concrete to check afterward.

Run: `./scripts/down.sh` (type `destroy` to confirm), then `./scripts/up.sh`.
Expected: `up.sh` reports restoring from the snapshot `down.sh` just took; once `terraform apply` finishes and the ECS service stabilizes (`aws ecs wait services-stable --cluster fleet-homelab --services fleet`), log into `https://<fleet_subdomain>` and confirm the org name, host count, and your break-glass/GitOps-CI accounts are all exactly as they were before teardown.

- [ ] **Step 5: Commit**

```bash
git add scripts/
git commit -m "Add up/down cost-control scripts with Aurora snapshot restore"
```

---

### Task 15: Remote execution via GitHub Actions (OIDC) — no long-lived AWS keys in GitHub

**Built 2026-10-07; the files in the repo supersede the code blocks below.** Differences from this design:
- **Repo IDs:** owner and repo IDs come from `terraform.tfvars` locally and from the `github` context in CI; the repo ID changes whenever the repo is recreated, and the apply and plan trust subjects must then be re-applied (`oidc.tf`, locally).
- **Secrets (8):** `AWS_ROLE_ARN` (the apply role, so the account ID stays masked), `TF_STATE_BUCKET` (written to `backend.hcl` at run time), `FLEET_SUBDOMAIN`, `FLEET_LICENSE_KEY`, `CLOUDFLARE_ZONE_NAME`, `CLOUDFLARE_API_TOKEN`, `BUDGET_ALERT_EMAIL`, `WAF_CI_HEADER_VALUE`; each set by piping from the local `terraform.tfvars`, `backend.hcl` or a Terraform output.
- **Workflow:** actions pinned to commit SHAs (`checkout` v7.0.1, `configure-aws-credentials` v6.3.0 with `mask-aws-account-id: true`, `setup-terraform` v4.0.1); an extra step masks the account ID for every later step; `TF_CLI_ARGS=-no-color`; `NO_GITOPS=1` because this repo's token cannot start the GitOps repo's workflow; generated `terraform.tfvars` and `backend.hcl` written with `umask 077` and removed at the end.
- **Scripts:** `tf-apply.sh`'s retry now passes `-input=false`, so a missing value fails instead of waiting on a prompt.
- **Also added:** `.github/CODEOWNERS`, `.github/dependabot.yml` (weekly: GitHub Actions, and Terraform for `/` and `/okta`), and Dependabot security updates on both repos. Dependabot opened its first PRs straight away.
- **Verified:** a CI `plan` run (manual, on `main`) assumed the apply role through OIDC and reported no changes; its public log contains no account ID, domain, state bucket, budget email, license key, Cloudflare token, WAF header or Okta org (79 values masked). **Not yet done:** the fork-PR test with a second GitHub account (Step 5), and real `up`/`down` runs from CI.

**Public Actions logs (this repo is public, so its workflow logs are too):** Terraform's plan, apply and destroy output prints resource IDs and ARNs, and ARNs contain the AWS account ID. Mask it at the start of every job before any AWS or Terraform step (`echo "::add-mask::$(aws sts get-caller-identity --query Account --output text)"`, a standard workflow command; verify it masks the ID inside longer strings during the first run), keep the Fleet URL and state bucket in secrets (GitHub masks secret values), and scan the first run's log for the ID, the hostname and the bucket name before relying on it. The Task 14 scripts already avoid printing the URL.

**Consequence of the account-ID rule for CI (2026-10-04):** the workflows cannot hard-code the state bucket or the account ID. Pass the bucket at init from a repository secret (for example `terraform init -backend-config="bucket=${{ secrets.TF_STATE_BUCKET }}"`), and take the role ARNs and account from secrets as well; also check the workflow logs for the account ID, since GitHub masks only values it knows are secrets (a secret is masked everywhere it appears, including inside a longer string). The plan and role outputs in Task 15 that say "substituted by hand into the two workflow files, same as the account ID in `backend.tf`" no longer hold: there is no literal account ID in the repo to mirror.

Up to this task, every `terraform apply`/`plan`/`destroy` — including `up.sh`/`down.sh` — runs from your own machine with your own AWS credentials. This task moves day-to-day `up`/`down`/`plan` to a manually-triggered GitHub Actions workflow, so they're runnable from anywhere (GitHub's UI, the mobile app, `gh workflow run` from any machine) without your laptop present. It's explicitly **not** auto-apply-on-push — you still press the button — because an infra `destroy` is a lot more consequential than a Fleet config sync, and this deployment's whole shape (mostly torn down) doesn't suit "apply whenever something merges" anyway. Local runs remain available for testing (`terraform plan` while iterating on `.tf` files), but shouldn't be the normal way `up`/`down` get triggered going forward.

**This repo is public (a portfolio piece), so the workflow runs on GitHub-hosted runners (`ubuntu-latest`), not a self-hosted one.** GitHub-hosted runners are free and unlimited for public repos, and — the real reason — GitHub explicitly warns against self-hosted runners on public repos: a fork pull request can edit the workflow file and run code on the runner, which here would be a machine on your home network. A GitHub-hosted job is a throwaway VM with no route to your LAN. (An earlier draft of this plan used a Proxmox LXC runner; that was dropped when the repo went public. Proxmox is still used for Grafana in Task 17.) OIDC works the same either way: GitHub mints the token server-side, so nothing about the trust setup depends on where the runner lives.

**Public-repo security model.** Only you have write access, so only you can merge, approve, dispatch workflows, or push branches. Strangers can open PRs from forks, but a fork PR gets no Actions secrets and a read-only token, and (with Step 5's setting) its workflows don't run at all until you approve them. The AWS side is the second lock: the apply role's trust is pinned to `workflow_dispatch` on `main` in this repo's immutable ID, so nothing a fork does can assume it.

**Two roles, not one** (an independent review found the single-role design could grant itself admin): an **apply role** for `up`/`down`/`plan` runs, assumable only by `workflow_dispatch` runs on `main`, and a **read-only plan role** for Task 16's pull-request checks, assumable only from the `pull_request` context. The apply role cannot modify either role or either role's policy (explicit `Deny`), so **any future change to `oidc.tf` gets applied locally as your admin SSO user, not by CI** — a `up` run that finds a pending `oidc.tf` diff will fail with `AccessDenied` on purpose, which is the signal to apply it by hand.

**Files:**
- Create: `oidc.tf`
- Create: `.github/workflows/terraform.yml`
- Create: `.github/CODEOWNERS`
- Modify: `variables.tf` (three GitHub ID variables)

**Interfaces:**
- Consumes: `scripts/up.sh`, `scripts/down.sh` (Task 14) — the workflow calls these directly rather than duplicating their logic, so local and CI runs can never drift apart. Also the repo's numeric GitHub owner/repo IDs (Step 2 — this is why the repo gets pushed to GitHub *first* in this task, before `oidc.tf` is even written).
- Produces: outputs `github_actions_apply_role_arn` and `github_actions_plan_role_arn` — substituted by hand into the two workflow files, same as the account ID in `backend.tf`.

- [x] **Step 1: Authenticate `gh`, pass the public-readiness gate, then push this repo to GitHub as a PUBLIC repo.** (If the repo was already published earlier in the project, skip to Step 2.) `gh` needs `gh auth login` (HTTPS + browser). The push has to happen before `oidc.tf` is written (see Step 2). **Creating a public repo is an outward-facing, effectively irreversible publish — confirm immediately before running the `gh repo create`.**

**Public-readiness gate — every item must pass before the first push** (history can't be cleanly un-published afterwards):
1. **Author email.** `git log --format='%ae %ce' | sort -u` must show only the GitHub noreply address (`<id>+<login>@users.noreply.github.com`; the numeric ID comes from `gh api user --jq .id`). If not, back up (`git bundle create ~/fleet-homelab-infra.bundle --all`), rewrite the history (no remote exists yet, so this is safe), and set `git config user.email` to the noreply address.
2. **No personal email in tracked files or history.** The Task 13 budget-alert address comes from a gitignored variable (`budget_alert_email`), never a literal. Both of these must print nothing: `git grep -niE '[a-z0-9._+-]+@(icloud|gmail|outlook|hotmail|yahoo)\.com'` (files) and `git log --all --oneline -G'[a-z0-9._+-]+@(icloud|gmail|outlook|hotmail|yahoo)\.com'` (history — an address scrubbed from the current files still sits in old commits; if it shows up there, rewrite the history, e.g. `git filter-repo --replace-text`, or squash to a fresh initial commit).
3. **No secrets, ever.** Scan the full history for the license key and the Cloudflare token (`git log --all -p -S<first 24 chars>`), and confirm `git log --all --name-only` never lists a `*.tfvars` (other than `example.tfvars`), state, plan or key file.
4. **Read the plan and spec once as a stranger would.** They describe the security design (break-glass admin, SSO, MFA); that's fine to publish, but nothing in them may contain a real credential, internal address or personal detail.

```bash
gh auth status || gh auth login
gh repo create fleet-homelab-infra --public --source=. --push
```

- [x] **Step 2: Get this repo's immutable numeric owner/repo IDs, and add them as Terraform variables.** Checked during execution, not something the original draft accounted for: **GitHub Actions OIDC tokens for any repository created after July 15, 2026 use an immutable subject-claim format by default** — `repo:OWNER@OWNER-ID/REPO@REPO-ID:...` instead of `repo:OWNER/REPO:...` — verified against GitHub's own changelog. This repo is created today, so it gets the new format with no opt-in. The old `repo:<owner>/fleet-homelab-infra:*` pattern would never match a real token.

```bash
gh api repos/<owner>/fleet-homelab-infra --jq '{owner_id: .owner.id, repo_id: .id}'
```

Add to `variables.tf`:

```hcl
variable "github_owner" {
  description = "GitHub username/org that owns this repo"
  type        = string
}

variable "github_owner_id" {
  description = "Numeric GitHub owner ID (immutable) -- needed for the post-2026-07-15 immutable OIDC subject-claim format."
  type        = string
}

variable "github_repo_id" {
  description = "Numeric GitHub repository ID (immutable) -- same reasoning as github_owner_id."
  type        = string
}
```

And the three values to `terraform.tfvars` (gitignored). CI doesn't need them stored anywhere: the workflows read them from the `github` context (`github.repository_owner`, `github.repository_owner_id`, `github.repository_id` — all three verified in GitHub's contexts reference).

- [x] **Step 3: Write `oidc.tf`.** The standard recipe for federating GitHub Actions to AWS without static keys: a `tls_certificate` data source reads GitHub's OIDC thumbprint (thumbprint validation is still part of the provider resource in 2025–26). The apply role trusts exactly one `sub` (`workflow_dispatch` run on `main` — a dispatch from any other branch carries a different `sub` and is refused); the plan role trusts exactly the `pull_request` `sub`. Both `sub` formats follow GitHub's statement that the branch/PR context "still appears after the repository segment" of the new format; the `pull_request` form is inferred from that sentence and the legacy `repo:ORG/REPO:pull_request` shape, not seen in a real token — see the check in Step 9.

```hcl
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
    sid     = "DenyChangingCiRolesAndPolicies"
    effect  = "Deny"
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
      "acm:Describe*", "acm:List*", "firehose:Describe*", "firehose:List*", "budgets:ViewBudget",
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
```

**What this is**: *scoped*, not formally least-privilege. Verified against IAM semantics: an earlier single-role draft (`iam:CreatePolicyVersion`/`PutRolePolicy`/`UpdateAssumeRolePolicy` on `*`, only `AttachRolePolicy` denied) let a compromised token rewrite its own policy — or any role's trust policy, including your SSO admin role — and become admin. What now closes that: IAM write limited to `fleet*`/`terraform-*` names, an explicit deny on changing either CI role or policy, no `sts:AssumeRole`, no IAM-user or OIDC-provider writes, `PassRole` limited to three consuming services, Secrets Manager and S3 scoped by name. **What remains, and can't be closed cheaply**: a compromised apply token can still create a new `fleet*`/`terraform-*` role with any policy and run code as it in an ECS task it also defines — closing that needs a permissions-boundary condition on every role it creates, and Fleet's modules expose no `permissions_boundary` input (grep of the whole repo finds none). It can also read the `fleet*` secrets and the state. The mitigation that fits is the trust policy: only a `workflow_dispatch` on `main` in your own private repo can assume it, and on a free GitHub plan private-repo branch protection isn't available, so anyone who can push to `main` (you) can change what it runs. An optional stronger gate, not built here: a GitHub Environment with a required reviewer, trusting `…:environment:<name>` instead of the `ref:refs/heads/main` subject, costs one approval click per run. Managed-policy size limit is 6,144 non-whitespace characters — this document is well under it, but check if you add to it.

- [x] **Step 4: Init, plan, and apply locally (as your admin SSO user), then record the ARNs.** This step adds the `tls` provider, so `terraform init` must run again before `validate` (a bare `validate` would fail with "provider not installed"). Regenerate the lock file for the platforms that will use it — you're on macOS, the runner is Linux, and a lock file with only macOS hashes can fail `terraform init` on the runner.

```bash
terraform init -upgrade=false
terraform providers lock -platform=darwin_arm64 -platform=linux_amd64 -platform=linux_arm64
terraform fmt && terraform validate && terraform plan -var-file=terraform.tfvars -out=tfplan && terraform apply tfplan
terraform output github_actions_apply_role_arn
terraform output github_actions_plan_role_arn
```

Expected: two ARNs like `arn:aws:iam::<ACCOUNT_ID>:role/fleet-homelab-github-actions` and `…-actions-plan` — save both for Step 7 and Task 16.

- [x] **Step 5: Lock down the public repo.** (Replaces the earlier Proxmox-runner provisioning: with a public repo, the risk to manage is fork PRs and Actions permissions, not a self-hosted machine.) In the repo's Settings — GitHub moves these labels around, so verify each at execution:
  1. **Actions → General → Fork pull request workflows:** "Require approval for all outside collaborators". Leave "send write tokens" and "send secrets" to fork-PR workflows **off**.
  2. **Actions → General → Workflow permissions:** "Read repository contents" only, and untick "Allow GitHub Actions to create and approve pull requests". API equivalent (verify the endpoint at execution): `gh api -X PUT repos/<owner>/fleet-homelab-infra/actions/permissions/workflow -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false`.
  3. **Actions → General → Actions permissions:** allow GitHub-owned actions plus only the `aws-actions/*` and `hashicorp/*` ones the workflows use; pin those third-party actions to full commit SHAs in the workflow files (Step 7), and add a Dependabot `github-actions` update config so the pins get refreshed.
  4. **Code security:** enable secret scanning, push protection, Dependabot alerts, and **private vulnerability reporting** (the README points reporters to the Security tab, which only works once this is on) — all free on public repos.
  5. **Ruleset on `main`** (Settings → Rules → Rulesets): require a pull request before merging with **0 required approvals** (GitHub does not let an author approve their own PR, and it doesn't matter here — only you have write access), require the `plan` status check once Task 16 exists, block force-pushes and deletions; put yourself (repository admin) on the bypass list so you can still push directly.
  6. **Collaborators:** confirm Settings → Collaborators lists nobody but you. Outsiders can still *open* PRs from forks — that can't be turned off on a public repo as far as verified (GitHub's interaction limits can restrict it to collaborators for up to 6 months; check for any newer "restrict pull requests" setting) — but they can't merge, approve, run unapproved workflows, or read secrets.
  7. **Optional, not recommended here:** a `production` environment with a required reviewer. Setting `environment:` on a job changes the OIDC `sub` claim to the `...:environment:production` form, so `oidc.tf`'s trust condition would have to change with it.

**Applied and verified via the API** (the repo was published and locked down in one session; these endpoints and payloads were run and read back, not just written down). `R=repos/<owner>/fleet-homelab-infra`:

```bash
# 1. approval required for all outside contributors' fork-PR workflows
gh api -X PUT $R/actions/permissions/fork-pr-contributor-approval -f approval_policy=all_external_contributors
# 2. read-only workflow token, Actions can't approve PRs
gh api -X PUT $R/actions/permissions/workflow -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false
# 3. only GitHub-owned + aws-actions/* + hashicorp/* actions, and SHA pinning enforced
gh api -X PUT $R/actions/permissions -F enabled=true -f allowed_actions=selected -F sha_pinning_required=true
gh api -X PUT $R/actions/permissions/selected-actions -F github_owned_allowed=true -F verified_allowed=false -f 'patterns_allowed[]=aws-actions/*' -f 'patterns_allowed[]=hashicorp/*'
# 4. secret scanning + push protection, Dependabot alerts, private vulnerability reporting; no wiki/projects
gh api -X PATCH $R -F 'security_and_analysis[secret_scanning][status]=enabled' -F 'security_and_analysis[secret_scanning_push_protection][status]=enabled'
gh api -X PUT $R/vulnerability-alerts
gh api -X PUT $R/private-vulnerability-reporting
gh api -X PATCH $R -F has_wiki=false -F has_projects=false
# 5. ruleset on the default branch (JSON below) — POST it with: gh api -X POST $R/rulesets --input ruleset.json
```

```json
{ "name": "protect-main", "target": "branch", "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "bypass_actors": [ { "actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always" } ],
  "rules": [ { "type": "deletion" }, { "type": "non_fast_forward" },
             { "type": "pull_request", "parameters": { "required_approving_review_count": 0,
               "dismiss_stale_reviews_on_push": true, "require_code_owner_review": false,
               "require_last_push_approval": false, "required_review_thread_resolution": false } } ] }
```

`actor_id: 5` is the built-in repository **Admin** role (that's you, the only collaborator — checked with `gh api $R/collaborators`). **Task 16 adds the `plan` required-status-check rule to this ruleset** once that workflow exists (a required check for a workflow that has never run would block every merge).

Verify: `gh api repos/<owner>/fleet-homelab-infra --jq '{visibility, has_issues}'` shows `public`; the settings above read back correctly in the UI. The real proof of the fork-PR controls is a manual test with a second GitHub account (or a throwaway one): fork the repo, open a PR that edits `.github/workflows/`, and confirm the run sits waiting for your approval and that no secrets or AWS role are available to it. Do this once after Step 9.

- [x] **Step 6: Add `CODEOWNERS` and commit**

```bash
mkdir -p .github && printf '* @<owner>\n' > .github/CODEOWNERS
git add .github/CODEOWNERS
git commit -m "Add CODEOWNERS"
```

- [x] **Step 7: Write `.github/workflows/terraform.yml`** — `runs-on: ubuntu-latest` (GitHub-hosted). Action majors verified current at execution (`checkout` v7, `configure-aws-credentials` v6, `setup-terraform` v4) and, per Step 5, pinned to full commit SHAs (keep the tag as a trailing comment). `terraform_version` pinned to the 1.14.8 you run locally. Inputs reach the shell only through `env:`, never spliced into script text. The `terraform.tfvars` step builds the file from repo secrets plus the three GitHub IDs, all read from the `github` context (verified); `printf` writes it with no leading whitespace (an earlier heredoc version indented every line). The hosted VM is discarded after the run, but the file holding the license key is still deleted at the end whether the run succeeded or not (belt and braces).

```yaml
name: Terraform

on:
  workflow_dispatch:
    inputs:
      action:
        description: "Action to run"
        required: true
        type: choice
        options:
          - plan
          - up
          - down
      confirm:
        description: "Required for 'down' — type exactly: destroy"
        required: false
        type: string

permissions:
  id-token: write
  contents: read

concurrency:
  group: terraform
  cancel-in-progress: false

jobs:
  terraform:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7

      - uses: aws-actions/configure-aws-credentials@v6
        with:
          role-to-assume: arn:aws:iam::<ACCOUNT_ID>:role/fleet-homelab-github-actions
          aws-region: us-east-1

      - uses: hashicorp/setup-terraform@v4
        with:
          terraform_version: "1.14.8"
          terraform_wrapper: false

      - name: Write terraform.tfvars
        env:
          FLEET_SUBDOMAIN: ${{ secrets.FLEET_SUBDOMAIN }}
          FLEET_LICENSE_KEY: ${{ secrets.FLEET_LICENSE_KEY }}
          CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
          CLOUDFLARE_ZONE_NAME: ${{ secrets.CLOUDFLARE_ZONE_NAME }}
          BUDGET_ALERT_EMAIL: ${{ secrets.BUDGET_ALERT_EMAIL }}
          GH_OWNER: ${{ github.repository_owner }}
          GH_OWNER_ID: ${{ github.repository_owner_id }}
          GH_REPO_ID: ${{ github.repository_id }}
        run: |
          {
            printf 'fleet_subdomain   = "%s"\n' "$FLEET_SUBDOMAIN"
            printf 'fleet_license_key = "%s"\n' "$FLEET_LICENSE_KEY"
            printf 'cloudflare_api_token = "%s"\n' "$CLOUDFLARE_API_TOKEN"
            printf 'cloudflare_zone_name = "%s"\n' "$CLOUDFLARE_ZONE_NAME"
            printf 'budget_alert_email = "%s"\n' "$BUDGET_ALERT_EMAIL"
            printf 'github_owner      = "%s"\n' "$GH_OWNER"
            printf 'github_owner_id   = "%s"\n' "$GH_OWNER_ID"
            printf 'github_repo_id    = "%s"\n' "$GH_REPO_ID"
          } > terraform.tfvars

      - name: terraform init
        run: terraform init -input=false

      - name: Plan
        if: inputs.action == 'plan'
        run: terraform plan -input=false -var-file=terraform.tfvars

      - name: Up
        if: inputs.action == 'up'
        run: ./scripts/up.sh

      - name: Down
        if: inputs.action == 'down'
        env:
          CONFIRM: ${{ inputs.confirm }}
        run: ./scripts/down.sh

      - name: Remove terraform.tfvars
        if: always()
        run: rm -f terraform.tfvars
```

Substitute the real apply-role ARN from Step 4 in place of `<ACCOUNT_ID>` (your account is where `backend.tf` already points). `scripts/up.sh` and `scripts/down.sh` also need `-input=false` on their `terraform` calls so a missing variable fails fast instead of hanging on a prompt in CI.

- [x] **Step 8: Add the five GitHub Actions repo secrets this workflow needs**

```bash
gh secret set FLEET_SUBDOMAIN --body "<fleet_subdomain>"
gh secret set FLEET_LICENSE_KEY --body "<your real Fleet Premium license key>"
gh secret set CLOUDFLARE_ZONE_NAME --body "<apex zone, e.g. example.com>"
gh secret set CLOUDFLARE_API_TOKEN   # prompts for the value so it never lands in shell history
gh secret set BUDGET_ALERT_EMAIL     # prompts; this repo is public, so the address must never be committed
```

- [x] **Step 9: Verify with a `plan` run**

Run: `gh workflow run Terraform -f action=plan && gh run watch`
Expected: the run executes on a GitHub-hosted runner and its log shows a `terraform plan` with no unexpected changes (the stack already matches what Tasks 3-14 applied locally).

If `configure-aws-credentials` fails with `Not authorized to perform sts:AssumeRoleWithWebIdentity`, the `sub` in the trust policy doesn't match what GitHub actually issued — print the real one and compare it to `oidc.tf` character for character (the immutable format and the `pull_request` form in particular were not seen in a real token when this plan was written):

```bash
# add as a temporary step before configure-aws-credentials (`jq` is preinstalled on ubuntu-latest)
curl -sH "Authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=sts.amazonaws.com" \
  | jq -r .value | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | jq -r .sub
```

- [x] **Step 10: Commit**

```bash
git add oidc.tf variables.tf .terraform.lock.hcl .github/workflows/terraform.yml
git commit -m "Add GitHub Actions OIDC roles (apply + read-only plan) and workflow_dispatch-triggered up/down/plan"
```

---

### Task 16: PR-triggered `terraform plan` checks — closing the GitOps loop for infra

**Before building: do not post the raw plan as a PR comment.** GitHub masks secret values only in Actions logs; a comment created through the API is posted as written, and the plan text contains ARNs with the account ID, the hostname and domain, bucket names and the budget email. On this public repo that would publish them. Post a summary instead (the `Plan: X to add, Y to change, Z to destroy` line and the list of changing resource addresses, which are names from the code, not values) and leave the full plan in the masked run log. Pull requests from forks and from Dependabot run without secrets or an OIDC token, so the check must skip them cleanly (as the GitOps repo's check does) rather than fail, or Dependabot PRs could never pass a required check.

The last piece: infra changes should go through a reviewed pull request that shows what would change, the same way the GitOps repo's PRs get a dry-run. This task adds that check without adding auto-apply-on-merge — see Task 15's opening note for why the latter is a bad fit here. The result: propose a `.tf` change → open a PR → CI shows the plan → merge → next time you run `up` (Task 15, on-demand), it deploys exactly what's on `main`. Git is the source of truth throughout; nothing ever applies from an uncommitted local change once this is in place.

This workflow assumes the **read-only plan role** from Task 15, not the apply role: a pull-request workflow runs the workflow file from the PR's own branch, so anything that can assume its role is only as trustworthy as whoever can open a PR. The plan role can read the stack and state but can't change anything. Fork PRs aren't a concern on a private repo with no collaborators — GitHub gives fork-triggered `pull_request` runs no secrets and no OIDC token anyway — but it's worth knowing if the repo is ever made public or gets collaborators.

**Files:**
- Create: `.github/workflows/terraform-plan.yml`

**Interfaces:**
- Consumes: `github_actions_plan_role_arn` (Task 15). Runs on GitHub-hosted runners like the apply workflow.

- [ ] **Step 1: Write `.github/workflows/terraform-plan.yml`.** Fixes from an independent review: the plan text used to be interpolated straight into the JavaScript source (`${{ steps.plan.outputs.stdout }}` inside a template literal), so a plan containing a backtick or `${` could inject code — it now travels through an environment variable and is read at runtime as data. `terraform_wrapper: false` means no dependency on a system `node` (the wrapper is what would have exposed `steps.<id>.outputs.stdout`), so output is captured to a file instead. `-lock=false` keeps the read-only role from needing any S3 write access (the lock file is a write) and stops a PR plan from blocking a running `up`; the tradeoff is a plan can occasionally read mid-apply state, which is harmless for a preview.

```yaml
name: Terraform Plan

on:
  pull_request:
    paths:
      - '**.tf'
      - '.terraform.lock.hcl'
      - '.github/workflows/terraform-plan.yml'

permissions:
  id-token: write
  contents: read
  pull-requests: write

jobs:
  plan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7

      - uses: aws-actions/configure-aws-credentials@v6
        with:
          role-to-assume: arn:aws:iam::<ACCOUNT_ID>:role/fleet-homelab-github-actions-plan
          aws-region: us-east-1

      - uses: hashicorp/setup-terraform@v4
        with:
          terraform_version: "1.14.8"
          terraform_wrapper: false

      - name: Write terraform.tfvars
        env:
          FLEET_SUBDOMAIN: ${{ secrets.FLEET_SUBDOMAIN }}
          FLEET_LICENSE_KEY: ${{ secrets.FLEET_LICENSE_KEY }}
          CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
          CLOUDFLARE_ZONE_NAME: ${{ secrets.CLOUDFLARE_ZONE_NAME }}
          BUDGET_ALERT_EMAIL: ${{ secrets.BUDGET_ALERT_EMAIL }}
          GH_OWNER: ${{ github.repository_owner }}
          GH_OWNER_ID: ${{ github.repository_owner_id }}
          GH_REPO_ID: ${{ github.repository_id }}
        run: |
          {
            printf 'fleet_subdomain   = "%s"\n' "$FLEET_SUBDOMAIN"
            printf 'fleet_license_key = "%s"\n' "$FLEET_LICENSE_KEY"
            printf 'cloudflare_api_token = "%s"\n' "$CLOUDFLARE_API_TOKEN"
            printf 'cloudflare_zone_name = "%s"\n' "$CLOUDFLARE_ZONE_NAME"
            printf 'budget_alert_email = "%s"\n' "$BUDGET_ALERT_EMAIL"
            printf 'github_owner      = "%s"\n' "$GH_OWNER"
            printf 'github_owner_id   = "%s"\n' "$GH_OWNER_ID"
            printf 'github_repo_id    = "%s"\n' "$GH_REPO_ID"
          } > terraform.tfvars

      - name: terraform init
        run: terraform init -input=false

      - name: terraform plan
        id: plan
        run: |
          set +e
          terraform plan -input=false -lock=false -no-color -var-file=terraform.tfvars > plan.txt 2>&1
          code=$?
          echo "exitcode=$code" >> "$GITHUB_OUTPUT"
          cat plan.txt
          delim="PLAN_$(openssl rand -hex 8)"
          { echo "PLAN_OUTPUT<<$delim"; tail -c 60000 plan.txt; echo; echo "$delim"; } >> "$GITHUB_ENV"
          exit 0

      - name: Comment plan on PR
        uses: actions/github-script@v9
        env:
          EXITCODE: ${{ steps.plan.outputs.exitcode }}
        with:
          script: |
            const body = `#### Terraform Plan (exit code ${process.env.EXITCODE})\n\`\`\`\n${process.env.PLAN_OUTPUT}\n\`\`\``;
            await github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: body.slice(0, 65000),
            });

      - name: Fail if plan failed
        if: steps.plan.outputs.exitcode != '0'
        run: exit 1

      - name: Remove terraform.tfvars and plan output
        if: always()
        run: rm -f terraform.tfvars plan.txt
```

Substitute the real plan-role ARN from Task 15 Step 4 for `<ACCOUNT_ID>`. The 65000-character slice guards GitHub's comment size limit; `github-script@v9` is ESM-only, so the script above deliberately uses no `require()` — only the injected `github`/`context` objects and `process.env`.

- [ ] **Step 2: Verify with a real PR**

```bash
git checkout -b test-plan-check
echo "# plan-check test" >> outputs.tf   # any .tf change triggers the path filter
git commit -am "Test PR plan check"
git push -u origin test-plan-check
gh pr create --title "Test PR plan check" --body "Verifying the plan-on-PR workflow"
```

Run: `gh pr checks` (or watch in the GitHub UI)
Expected: the "Terraform Plan" check runs and posts a plan output as a PR comment within a minute or two. An `AccessDenied` in the plan names the read call the plan role is missing — add it to `github_actions_plan` in `oidc.tf` and apply that **locally** (the CI apply role can't change either role). An `AssumeRoleWithWebIdentity` failure means the `pull_request` `sub` didn't match — use the token-inspection snippet in Task 15 Step 9.

- [ ] **Step 3: Clean up the test PR**

```bash
gh pr close test-plan-check --delete-branch
git checkout main
```

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/terraform-plan.yml
git commit -m "Add PR-triggered terraform plan checks, closing the GitOps loop for infra"
```

---

### Task 17: Grafana dashboard on Proxmox

Infra health (ALB/ECS/Aurora/Redis) plus Fleet asset data (host counts, policy compliance, vulnerabilities), visualized rather than just alarmed on. Runs on Proxmox, another LXC container alongside the GitHub Actions runner — no new AWS compute cost, and the dashboard stays reachable even when the Fleet stack itself is torn down, since both data sources it queries (CloudWatch, Fleet's REST API) are public AWS/HTTPS endpoints, not something inside the VPC. This task sets up the plumbing (the container, the two data sources, the credentials each needs); the actual dashboard panels are left for you to build hands-on, since "learn how Grafana works" was the actual goal here, not a pre-built dashboard. **It also builds alerting** (Steps 11-16) — Grafana's own native alerting on the same CloudWatch queries the dashboard uses, replacing what an earlier draft had as a separate Task 5 (standalone CloudWatch alarms + SNS). One monitoring system instead of two: an alert shows up next to the metric that fired it, and there's no second notification channel to maintain.

**A deliberate exception to this whole plan's "no long-lived credentials" pattern**: Grafana runs outside AWS with no equivalent to GitHub's OIDC federation available to it, so its CloudWatch data source needs a real, static AWS access key. Mitigated by scoping it to CloudWatch read-only actions alone (Step 3) — it cannot create, modify, or delete anything. (Task 18 adds a second such exception, an Entra client secret, for the same underlying reason — Grafana has no federated identity path into either cloud.)

**Files:**
- Create: `scripts/proxmox/create-grafana-lxc.sh`
- Create: `scripts/proxmox/bootstrap-grafana.sh`
- Create: `grafana-cloudwatch.tf`
- Create: `grafana-alerting.tf`

**Interfaces:**
- Consumes: nothing from earlier Terraform state directly — talks to CloudWatch and Fleet's API as an external client, the same way you would from a browser or `curl`.
- Produces: `aws_iam_access_key.grafana_cloudwatch` (Step 3's sensitive outputs, retrieved in Step 4 and pasted into Grafana's UI in Step 6), a read-only Fleet API token (created in Step 5, pasted into Grafana's UI in Step 7), and `aws_iam_access_key.grafana_ses_smtp` (Step 12's sensitive outputs, converted to an SES SMTP password in Step 13 and pasted into Grafana's own SMTP config in Step 14).

- [ ] **Step 1: Write `scripts/proxmox/create-grafana-lxc.sh`** — run on the Proxmox host to create the container. (Grafana is the only thing on Proxmox now — the CI runner moved to GitHub-hosted in Task 15 when the repo went public.)

```bash
#!/usr/bin/env bash
set -euo pipefail

# Adjust these for your Proxmox environment (storage pool, template and bridge names are specific to your Proxmox host).
VMID=901
HOSTNAME=fleet-homelab-grafana
TEMPLATE=local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst
STORAGE=local-lvm
BRIDGE=vmbr0
CORES=2
MEMORY=2048
DISK_GB=10

pct create "$VMID" "$TEMPLATE" \
  --hostname "$HOSTNAME" \
  --cores "$CORES" \
  --memory "$MEMORY" \
  --rootfs "${STORAGE}:${DISK_GB}" \
  --net0 name=eth0,bridge="$BRIDGE",ip=dhcp \
  --unprivileged 1 \
  --onboot 1 \
  --start 1

echo "Container $VMID created and started. Waiting for network..."
sleep 10
pct exec "$VMID" -- bash -c "apt update && apt install -y curl gnupg sudo"

echo "LXC $VMID is ready. Push and run the bootstrap script:"
echo "  pct push $VMID scripts/proxmox/bootstrap-grafana.sh /root/bootstrap-grafana.sh"
echo "  pct exec $VMID -- bash /root/bootstrap-grafana.sh"
```

- [ ] **Step 2: Write `scripts/proxmox/bootstrap-grafana.sh`** — installs Grafana OSS from its official apt repository, installs the Infinity plugin (Grafana Labs' own plugin for querying arbitrary REST/JSON APIs — not bundled with OSS core, confirmed via Grafana's own plugin docs), and starts it as a systemd service.

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "Adding the Grafana apt repository..."
apt update && apt install -y apt-transport-https software-properties-common wget gnupg
mkdir -p /etc/apt/keyrings
wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor > /etc/apt/keyrings/grafana.gpg
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
  | tee /etc/apt/sources.list.d/grafana.list

echo "Installing Grafana..."
apt update && apt install -y grafana

echo "Installing the Infinity data source plugin..."
grafana-cli plugins install yesoreyeram-infinity-datasource

echo "Starting Grafana..."
systemctl enable --now grafana-server

echo "Grafana is up on port 3000. Check its status: systemctl status grafana-server"
echo "Reach it at http://<this container's IP>:3000 (default login admin/admin, changes on first login)."
```

- [ ] **Step 3: Write `grafana-cloudwatch.tf`** — the scoped, read-only IAM user for Grafana's CloudWatch data source.

```hcl
resource "aws_iam_user" "grafana_cloudwatch" {
  name = "fleet-homelab-grafana-cloudwatch"
}

resource "aws_iam_user_policy" "grafana_cloudwatch" {
  name = "cloudwatch-read-only"
  user = aws_iam_user.grafana_cloudwatch.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "cloudwatch:GetMetricData",
        "cloudwatch:GetMetricStatistics",
        "cloudwatch:ListMetrics",
        "cloudwatch:DescribeAlarms",
        "cloudwatch:DescribeAlarmsForMetric",
        "cloudwatch:GetDashboard",
        "cloudwatch:ListDashboards",
        "tag:GetResources"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_access_key" "grafana_cloudwatch" {
  user = aws_iam_user.grafana_cloudwatch.name
}

output "grafana_cloudwatch_access_key_id" {
  value = aws_iam_access_key.grafana_cloudwatch.id
}

output "grafana_cloudwatch_secret_access_key" {
  value     = aws_iam_access_key.grafana_cloudwatch.secret
  sensitive = true
}
```

Note this is a plain `aws_iam_user`, not a role — deliberately, since it exists specifically to hold the one static credential this plan otherwise avoids. No mutating CloudWatch actions, nothing outside CloudWatch.

- [ ] **Step 4: Validate, plan, apply, and retrieve the key**

Run: `terraform fmt && terraform validate && terraform plan -var-file=terraform.tfvars -out=tfplan && terraform apply tfplan`
Then: `terraform output grafana_cloudwatch_access_key_id && terraform output -raw grafana_cloudwatch_secret_access_key`
Save both — the secret key only prints in full via `-raw`; treat it the same as any other credential (don't paste it anywhere but Grafana's own data source config in Step 6).

- [ ] **Step 5: 🎓 You run this — *(pre-flight: `fleetctl --version` → 4.92.0 and logged in, else stop; see Task 3 Step 8a)* create a read-only, API-only Fleet user for Grafana and get its API token** (logged in as an admin — the break-glass account before Task 9's MFA, or afterwards an SSO admin with a token from the UI's My account > Get API token via `fleetctl config set --token`)

```bash
fleetctl user create --name "Grafana" --global-role observer --api-only
```

Verified against Fleet v4.92.0: `--api-only` needs no email/password (there is no `--username` flag; an earlier draft used one and would have failed), and it **prints the API token once** — copy it immediately. This matters: a token obtained by `fleetctl login` as a normal user is a session token that expires (default 5 days), which would silently break Grafana's Fleet panels; an API-only user's token doesn't expire the same way, and it also doesn't depend on the break-glass account's MFA.

`observer` is the least-privileged role that can still read hosts, policies, and vulnerability data — matches Grafana's actual need (read dashboards' worth of data, nothing else).

- [ ] **Step 6: Configure the CloudWatch data source in Grafana**

In Grafana's UI (`http://<grafana-container-ip>:3000`): Connections > Data sources > Add data source > Amazon CloudWatch. Authentication: "Access & secret key", paste the values from Step 4. Default region: `us-east-1`.

- [ ] **Step 7: Configure the Infinity data source pointed at Fleet's API**

Connections > Data sources > Add data source > Infinity. Under Auth: Bearer Token, paste the token from Step 5. Base URL: `https://<fleet_subdomain>`.

- [ ] **Step 8: Verify both data sources connect**

In the CloudWatch data source's settings page, use "Save & test" — expect a success message. For Infinity, create a test query against `/api/v1/fleet/hosts/count` (Type: JSON, no auth override needed since it's set at the data source level) and confirm it returns a number, not an error.

- [ ] **Step 9: Build the dashboard.** Left open-ended on purpose. A few real, verified starting points to query against:
  - CloudWatch: the same ALB/ECS/Aurora/Redis metrics this task's own alert rules watch (Steps 11-16) — request count and 5xx rate, CPU/memory utilization, database connections.
  - Fleet, via Infinity: `GET /api/v1/fleet/hosts/count` (optionally repeated with `?platforms=darwin`/`windows`/`linux` for a platform breakdown), `GET /api/v1/fleet/global/policies` (each policy object includes `passing_host_count`/`failing_host_count` — verified against Fleet's own API reference), and `GET /api/v1/fleet/charts/cve` for vulnerability trends (Premium feature, available on this license).

- [ ] **Step 10: Build the up/down status board.** The point of this dashboard is being able to see at a glance whether each part of the Fleet stack is up, so build this first, before any of Step 9's performance panels. One "State timeline" or "Stat" panel per component, colored green/red on a threshold:
  - **Fleet itself** (Infinity → Fleet data source): `GET /healthz` on `https://<fleet_subdomain>`. A successful response is up; an error or timeout is down. This is the only true end-to-end check, since it goes through DNS, WAF, ALB, Fargate, and the database.
  - **ALB targets** (CloudWatch, namespace `AWS/ApplicationELB`): `HealthyHostCount` (green when >= 1) and `UnHealthyHostCount` (red when > 0), with the `LoadBalancer` and `TargetGroup` dimensions. Both are standard ALB metrics.
  - **Fargate** (CloudWatch, namespace `ECS/ContainerInsights`): `RunningTaskCount` for the `fleet` service (dimensions `ClusterName=fleet-homelab`, `ServiceName=fleet`), green when >= 1. Container Insights is enabled by default on the cluster the Fleet module creates (verified in `byo-db/variables.tf`), so this metric should exist without extra setup; confirm the panel returns data on the first run.
  - **Aurora** (CloudWatch, `AWS/RDS`): `DatabaseConnections` and `CPUUtilization` for the cluster. Aurora has no direct up/down metric, so treat "no data" as down.
  - **Redis** (CloudWatch, `AWS/ElastiCache`): `CurrConnections` and `EngineCPUUtilization` (both used by the monitoring addon). Same "no data means down" rule.
  - **Alert states**, once Steps 11-16 below build them: Grafana's built-in "Alert list" panel type shows each alert rule's current state (Normal/Pending/Firing) natively — no separate CloudWatch alarm system needed to populate this.

  One limit, worth knowing so the board isn't misread: this stack is torn down most of the time by design, so a fully red board usually means "torn down on purpose", not "broken" — a dashboard cannot tell those apart; read it alongside whether you've run `up`. (Unlike an earlier draft of this plan, Grafana does notify now — see Steps 11-16 — so this is no longer purely a passive display.)

- [ ] **Step 11: Write `grafana-alerting.tf`** — a second, separate IAM user scoped only to `ses:SendRawEmail`, purely so Grafana can authenticate to SES's SMTP interface. Deliberately not reusing Task 6's `module.ses` (that addon wires Fleet's own IAM-role-based API sending; Grafana runs outside AWS on Proxmox and needs SMTP username/password credentials instead — a different mechanism for the same underlying SES domain identity). Verified against AWS's own SES SMTP docs: SMTP credentials are derived from a plain IAM access key via a documented algorithm (Step 13), so this is a normal `aws_iam_user` + `aws_iam_access_key`, same shape as Step 3's CloudWatch user.

```hcl
resource "aws_iam_user" "grafana_ses_smtp" {
  name = "fleet-homelab-grafana-ses-smtp"
}

resource "aws_iam_user_policy" "grafana_ses_smtp" {
  name = "ses-send-only"
  user = aws_iam_user.grafana_ses_smtp.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ses:SendRawEmail"]
      Resource = "*"
    }]
  })
}

resource "aws_iam_access_key" "grafana_ses_smtp" {
  user = aws_iam_user.grafana_ses_smtp.name
}

output "grafana_ses_smtp_access_key_id" {
  value = aws_iam_access_key.grafana_ses_smtp.id
}

output "grafana_ses_smtp_secret_access_key" {
  value     = aws_iam_access_key.grafana_ses_smtp.secret
  sensitive = true
}
```

- [ ] **Step 12: Validate, plan, apply, and retrieve the key**

Run: `terraform fmt && terraform validate && terraform plan -var-file=terraform.tfvars -out=tfplan && terraform apply tfplan`
Then: `terraform output grafana_ses_smtp_access_key_id && terraform output -raw grafana_ses_smtp_secret_access_key` — same handling as Step 4's CloudWatch key (don't paste it anywhere but the SMTP conversion in the next step and Grafana's own config).

- [ ] **Step 13: Derive the SES SMTP password from the access key.** SES's SMTP password is *not* the IAM secret access key itself — it's a region-specific transform of it (HMAC-SHA256, versioned). Algorithm below is AWS's own, published at `docs.aws.amazon.com/ses/latest/dg/smtp-credentials.html` (verified there, not reconstructed from memory):

```python
import hmac, hashlib, base64

def ses_smtp_password(secret_access_key: str, region: str) -> str:
    date, service, terminal, message, version = "11111111", "ses", "aws4_request", "SendRawEmail", 0x04
    def sign(key, msg): return hmac.new(key, msg.encode(), hashlib.sha256).digest()
    k = sign(("AWS4" + secret_access_key).encode(), date)
    k = sign(k, region); k = sign(k, service); k = sign(k, terminal); k = sign(k, message)
    return base64.b64encode(bytes([version]) + k).decode()

print(ses_smtp_password("<secret from Step 12>", "us-east-1"))
```

The SMTP **username** is simply the access key ID from Step 12 (unchanged). Endpoint: `email-smtp.us-east-1.amazonaws.com`, port `587` with STARTTLS (verify against AWS's current SMTP endpoints table for `us-east-1` — general reference, `docs.aws.amazon.com/general/latest/gr/ses.html`).

- [ ] **Step 14: Configure Grafana's SMTP settings and an email contact point.** On the Grafana container, edit `/etc/grafana/grafana.ini`'s `[smtp]` section:

```ini
[smtp]
enabled = true
host = email-smtp.us-east-1.amazonaws.com:587
user = <access key ID from Step 12>
password = <SMTP password from Step 13>
from_address = grafana-alerts@<fleet_subdomain>
from_name = Grafana
startTLS_policy = MandatoryStartTLS
```

`systemctl restart grafana-server`. Then in the UI: Alerting > Contact points > Add contact point, type Email, address = your own inbox. **SES sandbox caveat, same one Task 6 already flagged for Fleet's own mail**: if the account hasn't been granted SES production access, the *recipient* address must be individually verified first (`aws sesv2 get-account --query ProductionAccessEnabled` to check; if `false`, verify your own address the same way Task 6 Step 3 describes) — the `from_address`'s domain is already verified via Task 6, but that alone doesn't let you send *to* an unverified address in sandbox mode.

- [ ] **Step 15: Build alert rules on the CloudWatch data source.** Alerting > Alert rules > New alert rule. Grafana-managed rules work against any data source that returns numeric data, CloudWatch included (verified against Grafana's own CloudWatch-datasource docs) — reuse Step 10's exact queries as the rule's query, add a Threshold expression, and set a evaluation group/interval (a few minutes is plenty for a homelab). Suggested starting rules, one per Step 10 panel:
  - ALB `UnhealthyHostCount` > 0
  - ECS `RunningTaskCount` < 1 for the `fleet` service
  - Aurora: no-data-as-alert on `DatabaseConnections` (mirrors Step 10's "no data means down" rule)
  - Redis: same no-data pattern on `CurrConnections`

  Point each rule's notification policy at the Email contact point from Step 14 (Alerting > Notification policies — the default policy routes everything to it unless you add label-based routing, which isn't needed at this scale).

- [ ] **Step 16: Verify with a real alert.** Temporarily lower one rule's threshold (e.g. the ECS one to `< 2`, which the normal `RunningTaskCount = 1` will trip) or use Grafana's rule-preview/test-run feature, and confirm the email actually arrives — don't just trust the rule was saved. Revert the threshold afterward.

- [ ] **Step 17: Commit**

```bash
git add scripts/proxmox/create-grafana-lxc.sh scripts/proxmox/bootstrap-grafana.sh grafana-cloudwatch.tf grafana-alerting.tf
git commit -m "Add Grafana on Proxmox: CloudWatch + Fleet API data sources, plus native alerting via SES SMTP"
```

---

### Task 18: Entra (Microsoft Graph) data source for Grafana — RETIRED

**Retired 2026-10-03 with the move from Entra to Okta (Task 10).** This task read Entra users, groups, devices and sign-in activity through Microsoft Graph; none of that exists any more. If a directory data source is wanted later, the equivalent is an Okta data source (a dedicated least-privilege API token or OAuth service app, Okta's Users, Groups and System Log APIs through an Infinity data source). **Not researched or designed**; do not build it from the old Graph steps, which remain in git history only.

---

### Task 19: Fleet activities webhook → Lambda → DynamoDB → Grafana

Added after the original 18 tasks, at my request, specifically to learn API Gateway + Lambda. Wires up Fleet's **activities webhook** (fires on essentially every event — logins, config changes, host enrollment; this is what logged the "starter library" activity flood in Task 3) to a small serverless pipeline: API Gateway (HTTP API) → an ingest Lambda → DynamoDB, plus a second read Lambda that Grafana's already-installed Infinity plugin (Task 17) queries for a fourth data source. Deliberately DynamoDB + a read Lambda rather than a community Grafana/DynamoDB plugin — it reuses the Infinity pattern already in this plan instead of installing an unvetted plugin.

**Verified against Fleet's own source before designing this** (`server/service/endpoint_setup.go`, `server/activity/internal/service/new_activity.go`, `server/platform/http/post_json.go`): the activities webhook is a plain `POST` of a fixed JSON shape (`timestamp`, `actor_full_name`, `actor_id`, `actor_email`, `type`, `details`), with **no signature or HMAC header of any kind** — Fleet does not authenticate its own outgoing webhook calls. Fleet's code already anticipates a secret living in the URL itself (a `MaskSecretURLParams` helper scrubs query-string values from its own logs before printing them), so that's the mechanism used here: a random token as a query parameter, checked by both Lambdas before doing anything else. This is the same shape of tradeoff as Task 17's plain IAM user — a static secret accepted because the alternative (no auth at all on a public endpoint) is worse, and Fleet gives no better option.

**Files:**
- Create: `webhook.tf`
- Create: `lambda/activities-webhook/ingest.py`, `lambda/activities-webhook/read.py`

**Interfaces:**
- Consumes: nothing from other `.tf` files (standalone, account-level resources, same as Task 13).
- Produces: `aws_apigatewayv2_stage.activities_webhook.invoke_url` — the ingest URL (`.../webhook`, used as Fleet's `destination_url` in Task 11's `default.yml`) and the read URL (`.../activities`, used in Task 17/18's Grafana as a fourth Infinity data source, added as an addendum there rather than repeated here).

- [ ] **Step 1: Write the two Lambda source files.** Kept intentionally minimal — the point is learning the API Gateway/Lambda wiring, not the application logic. Both check the same shared-secret query parameter before doing anything else; both use only `boto3`, which ships in the Lambda Python runtime (no dependency packaging needed).

`lambda/activities-webhook/ingest.py`:

```python
import json, os, time, uuid
import boto3

table = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])
TOKEN = os.environ["WEBHOOK_TOKEN"]
TTL_DAYS = int(os.environ.get("TTL_DAYS", "30"))


def handler(event, context):
    qs = event.get("queryStringParameters") or {}
    if qs.get("token") != TOKEN:
        return {"statusCode": 403, "body": "forbidden"}

    try:
        payload = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return {"statusCode": 400, "body": "invalid json"}

    now = int(time.time())
    details = payload.get("details")
    table.put_item(Item={
        "id": str(uuid.uuid4()),
        "ts": now,
        "type": payload.get("type", "unknown"),
        "actor_email": payload.get("actor_email"),
        "actor_full_name": payload.get("actor_full_name"),
        "details": json.dumps(details) if details is not None else None,
        "expires_at": now + TTL_DAYS * 86400,
    })
    return {"statusCode": 200, "body": "ok"}
```

`lambda/activities-webhook/read.py`:

```python
import json, os
import boto3

table = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])
TOKEN = os.environ["WEBHOOK_TOKEN"]


def handler(event, context):
    qs = event.get("queryStringParameters") or {}
    if qs.get("token") != TOKEN:
        return {"statusCode": 403, "body": "forbidden"}

    limit = int(qs.get("limit", "100"))
    # A Scan is fine at this scale (a homelab's occasional activity); it would
    # not be at real volume — noted rather than optimized, per this plan's
    # "avoid overcomplication" rule.
    resp = table.scan(Limit=limit)
    items = sorted(resp.get("Items", []), key=lambda i: i.get("ts", 0), reverse=True)
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(items, default=str),
    }
```

- [ ] **Step 2: Write `webhook.tf`.** Verified against the installed `hashicorp/aws` provider's own schema (`terraform providers schema -json`), not memory — this project has been burned twice already by invented schemas (the Task 4 WAF addon, the Task 3 module ALB path). Two Lambdas, two IAM roles (least-privilege, separate per function — same pattern as Task 15's two OIDC roles), one on-demand DynamoDB table with a TTL attribute for automatic cleanup, one HTTP API with two routes. `hashicorp/archive` is a new provider (add it to `providers.tf`'s `required_providers`, next to `cloudflare`).

```hcl
# providers.tf addition:
#     archive = {
#       source  = "hashicorp/archive"
#       version = "~> 2.4"
#     }

resource "random_id" "activities_webhook_token" {
  byte_length = 20
}

resource "aws_dynamodb_table" "fleet_activities" {
  name         = "fleet-homelab-activities"
  billing_mode = "PAY_PER_REQUEST" # a homelab's event rate never approaches provisioned-capacity territory
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }
}

data "archive_file" "ingest" {
  type        = "zip"
  source_file = "${path.module}/lambda/activities-webhook/ingest.py"
  output_path = "${path.module}/lambda/activities-webhook/ingest.zip"
}

data "archive_file" "read" {
  type        = "zip"
  source_file = "${path.module}/lambda/activities-webhook/read.py"
  output_path = "${path.module}/lambda/activities-webhook/read.zip"
}

data "aws_iam_policy_document" "activities_lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "activities_ingest" {
  name               = "fleet-homelab-activities-ingest"
  assume_role_policy = data.aws_iam_policy_document.activities_lambda_assume.json
}

resource "aws_iam_role" "activities_read" {
  name               = "fleet-homelab-activities-read"
  assume_role_policy = data.aws_iam_policy_document.activities_lambda_assume.json
}

resource "aws_iam_role_policy" "activities_ingest" {
  name = "fleet-homelab-activities-ingest"
  role = aws_iam_role.activities_ingest.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["dynamodb:PutItem"], Resource = aws_dynamodb_table.fleet_activities.arn },
      { Effect = "Allow", Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"], Resource = "arn:aws:logs:*:*:*" },
    ]
  })
}

resource "aws_iam_role_policy" "activities_read" {
  name = "fleet-homelab-activities-read"
  role = aws_iam_role.activities_read.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["dynamodb:Scan"], Resource = aws_dynamodb_table.fleet_activities.arn },
      { Effect = "Allow", Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"], Resource = "arn:aws:logs:*:*:*" },
    ]
  })
}

resource "aws_lambda_function" "activities_ingest" {
  function_name    = "fleet-homelab-activities-ingest"
  filename         = data.archive_file.ingest.output_path
  source_code_hash = data.archive_file.ingest.output_base64sha256
  role             = aws_iam_role.activities_ingest.arn
  handler          = "ingest.handler"
  runtime          = "python3.13" # verify the current runtime list at execution (python3.14 also exists as of this writing) — pinned to the stable one, not the newest
  timeout          = 10

  environment {
    variables = {
      TABLE_NAME    = aws_dynamodb_table.fleet_activities.name
      WEBHOOK_TOKEN = random_id.activities_webhook_token.hex
      TTL_DAYS      = "30"
    }
  }
}

resource "aws_lambda_function" "activities_read" {
  function_name    = "fleet-homelab-activities-read"
  filename         = data.archive_file.read.output_path
  source_code_hash = data.archive_file.read.output_base64sha256
  role             = aws_iam_role.activities_read.arn
  handler          = "read.handler"
  runtime          = "python3.13"
  timeout          = 10

  environment {
    variables = {
      TABLE_NAME    = aws_dynamodb_table.fleet_activities.name
      WEBHOOK_TOKEN = random_id.activities_webhook_token.hex
    }
  }
}

resource "aws_apigatewayv2_api" "activities_webhook" {
  name          = "fleet-homelab-activities-webhook"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_stage" "activities_webhook" {
  api_id      = aws_apigatewayv2_api.activities_webhook.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_apigatewayv2_integration" "ingest" {
  api_id                 = aws_apigatewayv2_api.activities_webhook.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.activities_ingest.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_integration" "read" {
  api_id                 = aws_apigatewayv2_api.activities_webhook.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.activities_read.invoke_arn
  integration_method     = "POST" # API Gateway always invokes Lambda via POST regardless of the route's method — this is not a typo
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "ingest" {
  api_id    = aws_apigatewayv2_api.activities_webhook.id
  route_key = "POST /webhook"
  target    = "integrations/${aws_apigatewayv2_integration.ingest.id}"
}

resource "aws_apigatewayv2_route" "read" {
  api_id    = aws_apigatewayv2_api.activities_webhook.id
  route_key = "GET /activities"
  target    = "integrations/${aws_apigatewayv2_integration.read.id}"
}

resource "aws_lambda_permission" "ingest" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.activities_ingest.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.activities_webhook.execution_arn}/*/*"
}

resource "aws_lambda_permission" "read" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.activities_read.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.activities_webhook.execution_arn}/*/*"
}

output "activities_webhook_ingest_url" {
  value = "${aws_apigatewayv2_stage.activities_webhook.invoke_url}webhook?token=${random_id.activities_webhook_token.hex}"
}

output "activities_webhook_read_url" {
  value     = "${aws_apigatewayv2_stage.activities_webhook.invoke_url}activities?token=${random_id.activities_webhook_token.hex}"
  sensitive = true
}
```

Tags: nothing extra needed — `default_tags` on the provider (Task 3) already applies `Project`/`ManagedBy` to every resource here that supports tags (the DynamoDB table, both Lambdas, the API). `aws_apigatewayv2_route`, `_integration`, `_stage`, `aws_lambda_permission`, and `aws_iam_role_policy` don't support tags in AWS at all — same "hangs off a tagged parent" situation as the resources noted in the tagging audit done for the rest of this stack.

- [ ] **Step 3: Init, validate, plan, apply**

Run: `terraform init && terraform fmt && terraform validate && terraform plan -var-file=terraform.tfvars -out=tfplan && terraform apply tfplan`
Expected: 1 DynamoDB table, 2 Lambda functions (+ 2 `archive_file` zips written to disk, gitignored — add `lambda/**/*.zip` to `.gitignore`), 2 IAM roles + inline policies, 1 HTTP API with 2 integrations/routes, 1 stage, 2 Lambda permissions.

- [ ] **Step 4: Verify the ingest path directly**, before touching Fleet — isolates "is the AWS side working" from "is Fleet configured right".

```bash
INGEST=$(terraform output -raw activities_webhook_ingest_url)
curl -s -o /dev/null -w "wrong token -> %{http_code}\n" -X POST "${INGEST%token=*}token=wrong" -d '{"type":"test"}'
curl -s -o /dev/null -w "correct token -> %{http_code}\n" -X POST "$INGEST" -d '{"type":"test.manual","actor_email":"you@example.com","details":{"note":"manual verification"}}'
aws dynamodb scan --table-name fleet-homelab-activities --query 'Items[?type.S==`test.manual`]' --output json
```

Expected: `403` then `200`, and the scan returns the item just written. Then the read endpoint:

```bash
curl -s "$(terraform output -raw activities_webhook_read_url)" | python3 -m json.tool | head -20
```

Expected: a JSON array containing that same item.

- [ ] **Step 5: Point Fleet's activities webhook at the ingest URL.** If Task 11's GitOps repo is already live, add this to `default.yml`'s `org_settings:` instead of running the command below, and commit/push it there — **not verified**: whether `fleetctl gitops`'s reconciliation resets `webhook_settings` to disabled when the key is entirely absent from `default.yml` (as opposed to explicitly present-and-disabled) is unconfirmed; check by adding it explicitly and watching the next scheduled gitops run rather than assuming either way.

```yaml
org_settings:
  webhook_settings:
    activities_webhook:
      enable_activities_webhook: true
      destination_url: "$FLEET_ACTIVITIES_WEBHOOK_URL"   # add FLEET_ACTIVITIES_WEBHOOK_URL to Task 11 Step 6's secrets and env block, value = Step 1's ingest URL (with its token)
```

If GitOps isn't live yet, set it directly (as the break-glass admin, `fleetctl` logged in per Task 3 Step 8a):

```bash
fleetctl get config --yaml > /tmp/fleet-config.yml
# edit /tmp/fleet-config.yml: under org_settings, add the webhook_settings block above
# with destination_url set to the real ingest URL from Step 1 (terraform output activities_webhook_ingest_url)
fleetctl apply -f /tmp/fleet-config.yml
rm /tmp/fleet-config.yml   # held the token in plaintext
```

- [ ] **Step 6: Verify end-to-end.** Trigger any real Fleet activity (log out and back in as the break-glass admin is enough — Task 3's screenshots already showed this fires on login) and confirm a new item lands: `aws dynamodb scan --table-name fleet-homelab-activities --query 'Items[?type.S==`user_logged_in`]' --output json`. Expect at least one item with a recent `ts`.

- [ ] **Step 7: Add a fourth Grafana data source (Infinity) for this** — addendum to Task 17/18 rather than a new Grafana setup. Connections > Data sources > Add data source > Infinity, Base URL = Step 1's read URL (the query-string token makes this the auth — no separate bearer/header config needed, unlike Task 17 Step 7's Fleet data source). Starting query: the URL as-is returns the 100 most recent activities as JSON — a table panel with columns `ts`, `type`, `actor_email` is a reasonable first panel; a time-series count-by-type view is a natural follow-on, left open-ended like Task 17 Step 9.

- [ ] **Step 8: No teardown wiring needed.** Unlike the Task 3 stack, nothing here bills hourly — DynamoDB on-demand, Lambda, and an HTTP API are all zero-cost at rest and near-zero at this event volume — so `scripts/down.sh`/`up.sh` (Task 14) deliberately do **not** target these resources; they simply stay up whether or not the Fleet stack is up (the webhook just has nothing to fire while Fleet itself is torn down).

- [ ] **Step 9: Commit**

```bash
git add webhook.tf lambda/ providers.tf .gitignore .terraform.lock.hcl
git commit -m "Add Fleet activities webhook -> Lambda -> DynamoDB -> Grafana"
```

---

### Task 20: End user SSO — authenticating device owners at MDM enrollment

> **Stale in places after the 2026-10-03 move to Okta.** The Fleet-side behavior below (callback, NameID-as-email, SCIM and certificate effects, YAML paths) is from Fleet's source and still holds. The **Entra-specific steps** (second Entra app, identifier-URI uniqueness, claims-mapping policy, Entra SCIM defaults) have **not** been redone for Okta: re-derive them (a second, separate Okta SAML app; Okta's SCIM provisioning to Fleet is unresearched) before building. Where the text says Entra, read Okta and verify.

Added after Task 19, at my request. **Not the same thing as Task 10/11's SSO.** That one logs *IT admins* into the Fleet console; this one makes the *person who owns a device* sign in with Entra while the device is being enrolled, before setup completes. Fleet's docs require two separate IdP apps if both are used ("the main differences between them will be the name and the callback URL"). Roles and just-in-time user creation apply only to the admin side; end users never get a Fleet account.

**What problem it solves** (Fleet's setup-experience guide): identity is verified before a device finishes enrolling; the person's IdP username, email and full name are stored on the host, so "whose device is this" is answered by the directory instead of by hand; on macOS the local account name and full name are filled in from the IdP and the local account is created; and the identity is available to configuration profiles and scripts as `$FLEET_VAR_HOST_END_USER_IDP_USERNAME` and `$FLEET_VAR_HOST_END_USER_EMAIL_IDP` (Fleet's own guide uses them for per-user Wi-Fi certificates). Fleet's YAML reference says it applies to macOS, Windows, Linux, iOS/iPadOS and Android.

**If it is not set up:** per Fleet's guide, "enrollment still works", but devices enroll without a verified person attached — anyone who can reach an enrollment path can enroll a device, ownership has to be recorded some other way, and the IdP variables have nothing to fill in. For one person and a few devices that is a small loss; the reason to build it is that it is what a normal organization does, and it exercises a real Fleet feature end to end.

**Verified from Fleet's source:**
- Config path is `org_settings.mdm.end_user_authentication`, which holds the standard provider fields (`entity_id`, `idp_name`, `metadata_url` or `metadata`). The per-fleet switch is `controls.setup_experience.enable_end_user_authentication` (Fleet's YAML reference).
- The callback is `/api/v1/fleet/mdm/sso/callback`. It takes the account **email from the NameID** and the display name from the assertion; the username is the email's local part. If the NameID is not an email, Fleet logs a warning and uses the raw value. **So the NameID must be mapped to `mail` exactly as in Task 10** — Entra's default NameID for an API-created app is an opaque hash, and that would silently give every device an unusable "email".

**Prerequisites:** Task 11 done and the admin login proven (this reuses the same pattern); a device to enroll. Per platform: Apple needs Apple MDM and Apple Business Manager (Task 8 Part B is still open, and what Apple Business Manager requires of a homelab has not been checked); Windows needs an enrollment path chosen (WSTEP is wired, Windows MDM is not yet turned on); Linux enrolls through fleetd/orbit and is the likeliest first test, for example a VM on Proxmox (Fleet's YAML reference says Linux supports it; the exact flow has not been checked).

**Identity changes and certificates (the "name change" problem other MDMs have with SCEP).** Fleet resolves the IdP variables **when it delivers a profile**, from what it stored about the host's identity at enrollment (`mdm_idp_accounts` and the host's `host_emails` mapping); if it can't find an IdP email, the profile **fails** with "couldn't populate `$FLEET_VAR_HOST_END_USER_EMAIL_IDP`". Nothing in end user authentication itself refreshes that stored identity afterwards. What does is **SCIM** (read from `server/datastore/mysql/scim.go`): when the IdP pushes a changed user, Fleet notes a changed `userName`, department, or given/family name. If `userName` moved **between two valid email addresses** (a UPN change), it renames the stored IdP account and rewrites the host's email mapping from old to new (and handles the case where the user already re-authenticated under the new address), then **resends** the profiles that use `IDP_USERNAME`, `IDP_USERNAME_LOCAL_PART`, `IDP_DEPARTMENT`, `IDP_FULLNAME` (all hosts of that user) and `HOST_END_USER_EMAIL_IDP` (hosts whose email moved), recording a "resent certificate" activity per certificate template. So **with SCIM, a UPN change reissues the certificate on its own; without SCIM, I found no other path that refreshes the stored identity** — the host keeps resolving the old address, nothing resends, and automatic renewal would re-resolve the same stale value, until the person re-enrolls or re-authenticates.

**Fleet does not revoke the old certificate** (for DigiCert a changed variable also takes a new seat and license); the old one lives until it expires or is revoked at the CA, so revoke it there if the old identity could still authenticate. Fleet auto-renews 30 days before expiry on Apple, Windows and Android (not Linux), which needs `$FLEET_VAR_CERTIFICATE_RENEWAL_ID` in the OU (36 characters; NDES truncates an OU at 64).

**Design consequences (my recommendations, derived from the above):** (1) For certificates that must carry the **user's UPN** in the CN (802.1X-style user identity), a UPN change *must* produce a new certificate, so plan on **SCIM provisioning from Entra to Fleet** being part of this task; for device-identity certificates, key the subject to the device (`%HardwareUUID%` plus the renewal ID) and a rename never reissues anything. (2) **Keep the two identities aligned:** the rename logic compares the old SCIM `userName` with the stored IdP email, so map the end-user app's NameID to the same attribute SCIM sends as `userName` (Entra's SCIM default is the UPN; Microsoft allows `user.userprincipalname` as a NameID source), or a rename can slip past hosts whose stored email doesn't match. (3) To put the **full address** in a CN use `$FLEET_VAR_HOST_END_USER_EMAIL_IDP`; the stored `username` is the email's **local part**, so the `IDP_USERNAME` variables may not carry the full UPN (unverified which one each resolves to). Not verified: Entra's SCIM provisioning setup against Fleet's endpoint, and whether SCIM also renames or deletes the matching *Fleet admin* account (the admin side, Task 10, creates a second account on an email change; I found no code that renames it).

**Files:**
- Create: `okta/enduser.tf`, and `fleet_enrollees` in `okta/variables.tf` / `example.tfvars`.
- Modify: Task 11's `default.yml` (the `end_user_authentication` block and the per-fleet switch) and its secrets list (add `FLEET_END_USER_OKTA_METADATA_URL`).

- [ ] **Step 1: A second Entra app in `entra/`** (`enduser.tf`), following Task 10's pattern, with these differences: the identifier URI must be **different** from the admin app's (Entra requires identifier URIs to be unique within a tenant) yet still on the verified domain, for example `https://<fleet_subdomain>/mdm` — unverified until apply; the reply URL is `https://<fleet_subdomain>/api/v1/fleet/mdm/sso/callback`; `app_role_assignment_required = true`; **no app roles** (Fleet reads no role from this app), so access is granted by assigning a "Fleet Enrollees" group (members from a `fleet_enrollees` list, like Task 10's two lists) with the default access role; a claims-mapping policy mapping the NameID to `user.mail` **and** the `http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name` claim to `user.displayname` (Fleet takes the display name from the first of `name`, `displayname`, `cn`, `urn:oid:2.5.4.3` or that `.../claims/name` URI that it finds — `server/sso/authorization_response.go` — and Entra's default for that claim is the UPN, so without this every enrolled device's full name, and the macOS account's, is the email address; unverified that Entra lets this basic claim be overridden, check with a captured assertion), plus `mapped_claims_enabled = true`; and its own token-signing certificate, which a portal-less app does not get automatically. Outputs: the entity ID and the metadata URL (sensitive).
- [ ] **Step 2: Verify in the tenant, then with a real assertion** the way Task 10 did: Graph shows SAML mode, the group assignment and the policy; the metadata carries signing keys; a captured assertion has the NameID as an email, a display-name attribute, and the right audience. **Do not enable "Allow SSO login initiated by identity provider"** on the Fleet side for this app (it is a Fleet-users setting and removes the request-binding that protects the login).
- [ ] **Step 3: Fleet configuration through the GitOps repo (Task 11).** Add `org_settings.mdm.end_user_authentication` (entity ID, `idp_name`, and `metadata_url: "$FLEET_END_USER_OKTA_METADATA_URL"`), then `controls.setup_experience.enable_end_user_authentication: true` on the fleet that will hold the test device. Order matters: Fleet validates that the IdP block exists before the per-fleet switch can be enabled (stated for the related Fleet Desktop setting in `server/fleet/app.go`; expected, not confirmed, for this one), so keep both in the same change.
- [ ] **Step 4: Enroll a test device and verify.** Host details should show the IdP username and full name of whoever signed in, and a device should not finish setup without signing in. Record which platform was tested; the Windows and Linux flows are the least certain.
- [ ] **Step 5: SCIM provisioning (needed if certificates carry the UPN or email).** Configure Entra's provisioning for this enterprise app to push users to Fleet's SCIM endpoint, then rename a test user's UPN and confirm the host's IdP email changes, the profile is resent, and a "resent certificate" activity appears. Setup details are not yet researched or verified.
- [ ] **Step 6: Commit** `okta/enduser.tf`, the variable and example changes, and the GitOps repo change (separate repo, separate commit). Never commit `okta/terraform.tfvars`.

---

### Task 21: Health and error scan — are all the components working?

Added at my request. A read-only runbook to run **while the stack is up** (Fleet's CloudWatch logs are destroyed with the stack, and the app log group keeps only 5 days). First baseline run: 2026-10-05, after the Okta, GitOps and Aurora 3.13.0 work.

**Where Fleet's app logs are.** Fleet writes JSON logs to stdout (`FLEET_LOGGING_JSON=true`); ECS ships them to a CloudWatch log group named `terraform-<hash>` (the module's unnamed default, 5-day retention). Not to be confused with osquery result and status logs (Task 12, Firehose to S3) or Fleet's activity feed (Task 19 sends it to a webhook). The Container Insights group holds ECS metrics only.

**Checks** (all read-only):
1. **ECS:** running equals desired, rollout `COMPLETED`, no stopped tasks, recent service events.
2. **Fleet app logs** (Logs Insights, last 3 days): counts by `level`; top `error` and `warn` messages grouped by `msg`; keyword hits for `panic`, `fatal`, `out of memory`, `connection refused`, `deadlock`, `too many connections`, `context deadline`, `timeout`.
3. **ALB:** target health; three-day sums of `RequestCount`, 2xx, 4xx, `HTTPCode_Target_5XX_Count`, `HTTPCode_ELB_5XX_Count`; response-time average and maximum.
4. **Aurora:** `describe-events` for the last 3 days, pending maintenance; CPU, `CPUCreditBalance` (burstable class), `FreeableMemory`, connections.
5. **Fargate task:** CPU and memory utilization, average and maximum.
6. **Redis:** events, `EngineCPUUtilization`, evictions.
7. **WAF:** allowed versus blocked requests (CloudWatch `AWS/WAFV2`).
8. **SES:** send statistics (bounces, complaints, rejects) and enforcement status.
9. **Certificate and DNS:** ACM status, expiry and renewal eligibility; the delegated nameservers and the A record resolve.
10. **Budget:** actual and forecast against the limit.
11. **Fleet itself:** `/healthz`, `/api/v1/fleet/status/result_store` and `/status/live_query` (an empty object means healthy), and the GitHub gitops workflow runs and security alerts on both repos.
12. **Not covered from here:** Okta's System Log (the service app has no `okta.logs.read` scope, so look in the console under Reports), CloudTrail, Cloudflare, and Fleet's activity feed (its API path returned 404 on 4.92; use the UI).

**Baseline findings, 2026-10-05, everything benign:**
- **App logs, 3 days (about 38,000 records):** 38,276 info, 40 error, 6 warn. 38 of the errors were one message, `unlock failed` (the `automations` cron), all within one hour and just before a deliberate service restart: a job lost its database lock while the old task shut down. Two errors were `invalid role: unassigned`, the intended refusal from the Okta direct-assignment test. The warnings were empty-role notices from before that fallback existed and API-path deprecation notices from `fleetctl api` calls.
- **Load balancer:** about 1,800 requests, no target 5xx; 6 load-balancer 5xx in a single minute during the first rebuild attempt, when the ALB was up and the task was not.
- **Aurora:** CPU averaged 13% (maximum 57%); memory minimum about 1.2 GB; at most 18 connections. The CPU credit balance touched 0 right after instance creation (restore and migrations) and then climbed past 100, with no surplus credits charged.
- **Fargate:** CPU averaged 3% (spiked to 100% at boot); memory maximum 41%. **Redis:** no evictions, negligible CPU.
- **WAF:** about 4,000 allowed and about 31,500 blocked over 3 days (the US-only rule blocks foreign scanners). **SES:** 6 sends in 24 hours, no bounces or complaints, status healthy (sandbox). **Certificate:** issued, renews automatically, expires April 2027. **DNS:** delegation and the alias record resolve. **Budget:** about $6.70 spent against a $100 limit, forecast about $14. **GitHub:** the latest gitops run succeeded and there are no Dependabot or secret-scanning alerts.

**Possible follow-ups, not built:** keep Fleet's app logs beyond teardown (a subscription to S3, or a named log group kept outside the teardown), alarms on the error rate, and a scheduled version of this scan.

---

## Spec coverage check

- Identity/SSO (Okta + break-glass + JIT provisioning + group-based role mapping; replaced Entra on 2026-10-03): Task 3 Step 8 (break-glass created via `fleetctl setup`), Tasks 10, 11 (SSO/JIT/roles), Task 9 (break-glass MFA, after SSO is verified). ✓
- Device enrollment (Windows/macOS/Linux): Tasks 7-8 (Windows via WSTEP secret + `windows_enabled_and_configured` in Task 11; macOS via APNs cert uploaded in the Fleet UI), Task 11 fleet enroll secret covers Linux via `fleetd`. ✓
- Infra sizing (root module, NAT on, Aurora `db.t4g.medium` no replica, Redis `t4g.small`, Fargate 512/4096): Task 3. ✓
- WAF: Task 4. SES: Task 6. ✓ (Monitoring folded into Task 17's native Grafana alerting — see Task 5.)
- DNS/TLS: Task 2. ✓
- GitOps: Task 11. ✓
- Osquery log destination (Firehose → S3): Task 12. ✓
- AWS Budget alert ($100/mo, an alert every $10): Task 13. ✓ (built and applied)
- Cost-control scripts, with real state preservation across teardown (Aurora snapshot restore, externalized private key, MDM secrets excluded from destroy): Task 14. ✓
- HA/replicas deliberately excluded regardless of cost: Global Constraints + Task 3 note. ✓
- Health and error scan of the running stack (runbook plus baseline): Task 21.
- Remote (non-laptop) execution of `up`/`down`/`plan` via GitHub Actions OIDC, no long-lived AWS keys in GitHub: Task 15. ✓
- Full GitOps loop for infra (PR shows plan, merge updates the source of truth, on-demand apply — not auto-apply-on-merge): Task 16. ✓
- Grafana dashboard on Proxmox, CloudWatch + Fleet API data sources, plus native alerting via SES SMTP (replaces the standalone CloudWatch-alarms design): Task 17. ✓
- Entra (Microsoft Graph) data source for Grafana: Task 18, retired with the move to Okta.
- Two-repo layout: this repo (Tasks 1-9, 12-18) + `fleet-homelab-gitops` (Task 11). ✓
- Fleet activities webhook -> Lambda -> DynamoDB -> Grafana (added at my request, to learn API Gateway/Lambda): Task 19.
- End user SSO (device owners authenticate with Okta during MDM enrollment; a second Okta app, separate from the admin SSO; Okta-specific steps not yet derived): Task 20.
