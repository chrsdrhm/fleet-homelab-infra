# Fleet Premium on AWS — homelab deployment design

Started: 2026-09-17
Status: built and running (Tasks 12, 17, 19 and 20 in the plan are still open); kept up to date as the build changes

## Goal

Deploy a "real" Fleet Premium instance into my own
AWS account: publicly accessible over HTTPS, federated to Okta for SSO,
managed via Fleet GitOps, and reasonably secure — while minimizing recurring
AWS cost, since this is for personal homelab learning, not production scale.

## Non-goals (explicitly deferred)

- **Apple Business Manager / zero-touch enrollment** — needs a registered
  business entity; manual/QR Apple MDM enrollment is used instead.
- **Multi-AZ / HA (read replicas, Redis failover, min 2+ Fargate tasks)** —
  deliberately skipped regardless of cost, since my priority
  is "if it breaks, I rebuild it," not uptime during an incident. This is
  independent of the cost decisions below: Aurora/Redis/Fargate are sized
  for headroom and data durability, not for seamless failover. A documented
  future upgrade if that priority ever changes.
- **Automated scheduled pause/resume** (Lambda + EventBridge) — I chose
  manual scripts only, no auto-scheduling.

## Identity & access

- **Primary IdP: Okta** (changed from Entra ID on 2026-10-03). Entra was built
  and worked, but could not meet the requirement that nobody holds a Fleet
  role unless explicitly assigned: Fleet creates a new SSO user with no role
  claim as a global observer, and Entra lets Global Administrators sign in
  to any app regardless of "assignment required" (only a Conditional Access
  policy holds them). Okta refuses unassigned users, super
  admins included (verified in the build, plan Task 10 Step 5). Fleet's SSO is
  generic SAML, so nothing in the AWS infrastructure changed.
- **The Okta org: a Workforce Identity free trial that becomes a Free Plan.**
  Signed up at okta.com/free-trial (work email, name, phone and country); the
  org gets a generated `trial-<number>.okta.com` address. The trial runs 30
  days with everything on, then converts automatically to a Free Plan: up to
  10 users, single sign-on, Universal Directory and MFA, no support, and Okta
  may end an org after 45 days of inactivity, so an admin signs in at least
  monthly (a calendar reminder). Cost: $0. Rejected: the Integrator Free plan,
  whose terms exclude production use, and paid Starter ($1,500 annual minimum).
  If Okta ever ends the org, the SSO setup is Terraform and rebuilds in a new
  org quickly.
- **Terraform's access to Okta** is an OAuth 2.0 **API Services** app (in this
  org's console it is under Create App Integration → **Classic experience**),
  using client credentials with a key pair: the provider signs a short-lived
  assertion with the private key and gets a one-hour access token on each run.
  The app is granted the `okta.apps.manage` and `okta.groups.manage` scopes and
  the **Super Administrator** role (Organization Administrator was not enough to
  create the SAML app). The private key, shown once, lives in a file outside
  the repo; the client ID, key ID and the key's path are in the gitignored
  `okta/terraform.tfvars`. Better than an API token, which Okta revokes after
  30 days unused, but still a static credential, which is one reason `okta/`
  is applied locally and never from CI.
- **JIT provisioning + group-based role mapping** (Premium): SAML SSO
  configured via Fleet GitOps `org_settings.sso_settings` (`entity_id`,
  `idp_name`, `metadata_url`, `enable_sso_idp_login`, `enable_jit_provisioning`).
  With JIT provisioning on, Fleet accounts are created automatically on first
  SSO login rather than needing to be pre-created. The role a JIT-provisioned
  account gets comes from a custom SAML attribute, `FLEET_JIT_USER_ROLE_GLOBAL`
  (accepted values: `admin`, `maintainer`, `observer`, `observer_plus`,
  `technician`, `null`) — this is entirely an IdP-side mechanism, not a
  Fleet-side mapping table: two Okta groups ("Fleet Admins", "Fleet Observers")
  are assigned to the Okta SAML app, and an attribute statement emits `admin`
  or `observer` from group membership (admin wins if a user is in both,
  which avoids Fleet silently taking the last role value it is sent), and
  `unassigned` otherwise: Fleet rejects that invalid value, so a user who
  reaches the app without either group (for example by a direct assignment)
  cannot sign in instead of keeping or getting a role. The Okta
  side is Terraform (`okta/`, separate state, applied locally, never from CI),
  except **group membership, which is never managed by Terraform** and is set
  by hand in the Okta console. Per-team role mapping
  (`FLEET_JIT_USER_ROLE_FLEET_<team_id>`) is possible later but needs the
  numeric team ID Fleet assigns once the "Workstations" team exists — a
  deliberate follow-up, not part of this pass, to avoid a chicken-and-egg
  with team creation.
- **End user SSO (Task 20)**: separate from admin SSO. Device owners
  authenticate with a second Okta app (the
  `/mdm/sso/callback` URL, NameID mapped to email) during MDM enrollment, so
  each host carries a verified IdP identity. Fleet requires two IdP apps if
  both are used; roles and JIT apply only to the admin side. Not built until
  the admin SSO is proven and there is a device to enroll.
- **Break-glass account**: one Fleet global admin created via
  `fleetctl setup` — Fleet's first-run bootstrap, immediately after the first
  deploy (a fresh Fleet has no users, and `fleetctl user create` needs an
  existing session) — password auth, not SSO-linked, *before* SSO is
  enabled. Fleet allows password-auth and SSO-auth users to coexist, so this
  account stays reachable at `/login` after SSO is turned on. Credentials go
  in my personal password manager — deliberately *not* AWS Secrets
  Manager, so an IAM/AWS-side problem can't also lock out the break-glass
  path. JIT provisioning has no effect on this account since it isn't
  SSO-authenticated. **MFA (enabled 2026-10-04, after SSO was proven)**: it's the one account
  protected by a password alone (SSO users get the IdP's own MFA), so it can get
  Fleet's email-based MFA (Premium, needs SMTP — provided by the SES addon).
  Enabled only *after* SSO is verified as a second way in, because MFA users
  can't use `fleetctl login` and a mail failure would otherwise lock out the
  only account. The AWS account's SES is in the sandbox, so the recipient
  address must be a verified SES identity, created outside Terraform so it
  survives the SES module's teardown (or request SES production access). If
  MFA is skipped, the residual risk is a single-factor admin behind a long
  random password and the WAF.
- **GitOps API user**: separate API-only Fleet user (`--api-only`, created
  by the break-glass admin; its non-expiring token is printed once) with the
  `gitops` role, scoped to CI use only — distinct from the break-glass admin. Also
  unaffected by JIT provisioning for the same reason.

## Device enrollment

- **Windows**: `enable_windows_mdm = true` plus
  `controls.windows_enabled_and_configured: true` in GitOps. Requires a
  WSTEP identity certificate/key pair (self-signed RSA-4096, generated once
  with `openssl`) stored in the `addons/mdm` `fleet-scep` secret in AWS
  Secrets Manager. The pair must be backed up: replacing it permanently
  loses escrowed BitLocker keys.
- **macOS**: free Apple APNs cert (via Apple ID, annual renewal). Fleet
  generates the SCEP CA and APNs key itself and stores them encrypted in its
  database (surviving teardown via the Aurora snapshot + the externalized
  Fleet private key); the admin generates the CSR with
  `fleetctl generate mdm-apple`, gets the cert from Apple's Push Certificates
  Portal and uploads it in the Fleet UI — no AWS secret involved. The CSR is
  signed by fleetdm.com using the logged-in admin's email, which may need to
  be a non-personal domain. ABM/DEP is not configured (manual/QR enrollment
  only).
- **Linux**: `fleetd` agent enrollment via the team's enroll secret. No MDM
  cert needed.

## AWS infrastructure

Built from `github.com/fleetdm/fleet-terraform`, region `us-east-1`. Uses the
**root module directly** — the single most "default" way to consume this
codebase, matching Fleet's own reference example almost verbatim. One
module call provisions the VPC, Aurora, Redis, ALB, and ECS together,
wiring subnets, connection info, and security groups automatically. Two
earlier drafts of this design used progressively more customized entry
points into the same module family (first `byo-db` for a hand-rolled plain
RDS instance, then `byo-vpc` with a separately hand-written VPC) — both
existed only to support configurations this design no longer uses (plain
RDS instead of Aurora; NAT-off with public-subnet Fargate). With Aurora and
NAT both back, nothing justifies the extra layer anymore, so this reverts
to the root module and drops ~90 lines of Terraform that were re-specifying
the module's own default CIDR ranges, subnet layout, and NAT settings
verbatim.

**Why the reversal from the original cost-cut version**: nearly every
per-hour-billed resource here (RDS, Redis, Fargate, NAT, ALB) was sized down
specifically to minimize an *always-on* monthly bill. But my actual
usage pattern is intermittent — running mostly evenings/weekends via full
`terraform destroy`/`apply` cycles (see Teardown tooling below), not
continuously. Under that pattern, the delta between the cheap and the
"real"/recommended sizing shrinks to a few dollars a month, so there's
little reason to carry the operational downsides of the cheapest tier
(RDS memory headroom risk, no defense-in-depth on the network egress path)
just to save single-digit dollars. High-availability features (replicas,
failover, redundant tasks) are a separate, deliberately-skipped axis — see
Non-goals above.

| Component | Decision |
|---|---|
| VPC | 3 AZs (module requirement for subnet groups; us-east-1a, 1f and 1c, chosen when Aurora was `db.t4g.medium`, orderable only in 1c and 1f; see the plan's Task 3); public, private, database, and elasticache subnets. **NAT Gateway restored** (single gateway, module default) — Fargate now runs in a private subnet with egress via NAT, not a public subnet. |
| Database | **Aurora MySQL** via the root module's built-in `rds_config`, engine 3.13.0 (MySQL 8.0.45, at or above Fleet's minimum of 8.0.44), `db.t3.medium` (`db.t4g.medium` until repeated capacity failures; see the plan's Task 3), single instance (`replicas = 1` — the total instance count in the root module, so one writer and no reader; see Non-goals), 7-day backup retention |
| Cache | ElastiCache Redis, `cache.t4g.small`, `cluster_size = 1` (no failover) |
| Compute | ECS Fargate, `cpu = 512`, `mem = 4096` (4GB required for vulnerability scanning, which stays **on**), `autoscaling.min_capacity = 1`, `max_capacity = 2`. Task now in a **private subnet**, NAT for egress, security group still only allows inbound from the ALB's security group. |
| Image | `fleetdm/fleet:v4.92.0`, pinned (the `quay.io` mirror is the fallback if Docker Hub rate limits ever bite) |
| ALB | Public, HTTPS via ACM (DNS-validated), target group → Fargate task |
| WAF | A Web ACL written in `waf.tf`, not Fleet's `addons/waf-alb` (which cannot express "allow only one country"): default block, an `allow-us` geo rule, and ahead of it an `allow-ci-header` rule that admits requests carrying a secret `x-fleet-ci` header, so GitHub-hosted runners outside the US can reach Fleet (Fleet still requires an API token). Geo-based only, not an AWS Managed Rule Group; it does not provide signature-based protection against SQLi/XSS-style attacks |
| MDM | `addons/mdm` — one `fleet-scep` secret holding the Windows WSTEP pair (Apple MDM is configured through the Fleet UI, `enable_apple_mdm = false`). Two-phase: secret created empty, populated, then wired into the task (an empty secret referenced by the task would fail to start). **Excluded from teardown** — see Teardown tooling. |
| Monitoring | No standalone CloudWatch-alarm addon: alerting is planned in Grafana on the same metrics (see Dashboard, optional), delivered through SNS. Until then, a read-only health scan runbook (plan Task 21) |
| Email | `addons/ses` — outbound mail for invites and break-glass password reset |
| Secrets | AWS Secrets Manager: Aurora password (module-managed), the Windows WSTEP pair (module-managed secret, persisted across teardown), Fleet server private key (created **outside** the Fleet module specifically so it survives `module.fleet` being destroyed — see Teardown tooling). AWS-managed KMS keys (no CMKs) throughout. |
| License | `FLEET_LICENSE_KEY` supplied as an environment variable on the ECS task, from the gitignored `terraform.tfvars` (a GitHub secret in CI) |
| Terraform state | S3 backend with native locking (`use_lockfile = true`) — no DynamoDB table; `dynamodb_table` was deprecated in Terraform 1.11 in favor of S3's own conditional-write locking |

### Sizing compared with Fleet's defaults and guidance

Fleet's root module defaults suit a production deployment, and Fleet's own
[reference architectures](https://fleetdm.com/docs/deploy/reference-architectures)
start at "up to 5,000 hosts". This homelab has about ten hosts, so it uses the
same building blocks at a much smaller scale. Each difference is an input to
Fleet's module (`fleet.tf`), not a change to the module itself.

| Component | Fleet module default | Fleet's smallest published tier (≤ 5,000 hosts) | This homelab (~10 hosts) |
|---|---|---|---|
| Region | us-east-2 (its `vpc.azs` default) | — | us-east-1; any region works |
| Availability zones | 3 | — | 3 |
| NAT Gateway | one, shared | — | one, shared (default kept) |
| Fleet server (Fargate) | 512 CPU / 4 GB; autoscaling 1–5 tasks at 80% CPU or memory | 6 tasks, 1024 CPU / 4 GB | 512 CPU / 4 GB; autoscaling 1–2 tasks |
| Aurora MySQL | `db.t4g.large`, 2 instances (writer and reader, automatic failover) | `db.t4g.medium`, 2 instances | `db.t3.medium` (same 2 vCPU / 4 GB as `db.t4g.medium`), 1 instance |
| Redis | `cache.m5.large`, 3 nodes | `cache.t4g.small`, 3 nodes | `cache.t4g.small`, 1 node |
| MySQL connections per task | — | `FLEET_MYSQL_MAX_OPEN_CONNS=10` | 10 |

**Why this doesn't hurt the experience at this scale:** one Fleet task and
one database instance of the size Fleet recommends for up to 5,000 hosts are
far more than ten hosts need (the health scan in plan Task 21 saw Aurora
average 13% CPU and the Fleet task 3%). The 4 GB of task memory is kept on
purpose, for vulnerability processing. Autoscaling still exists: it can add a
second task under load.

**What it gives up is resilience, not speed:** no Aurora reader to fail over
to, a single Redis node, and a single Fleet task, so a zone failure or a task
replacement means a short outage, and nothing is multi-region (Fleet's module
does not do multi-region; it would be a second deployment). For a homelab the
recovery plan is to rebuild from the snapshot. These choices are most of the
reason the stack costs about $200 a month when left running instead of
several times that, and each one is a single input to turn back up (see
Non-goals).

### DNS / TLS

My domain's DNS is hosted on Cloudflare. A Route 53 hosted zone is
created just for the `fleet.<domain>` subdomain; 4 NS records are added in
the Cloudflare dashboard to delegate only that subdomain to Route 53 — the
rest of the domain stays on Cloudflare, untouched. ACM validates the
certificate against the Route 53 zone. Fleet is **not** proxied through
Cloudflare's CDN (NS records can't be proxied regardless, and proxying the
`fleet` subdomain itself would be a bad fit for Fleet's long-lived
connections — live queries, MDM check-ins, software installer downloads).

## GitOps

The `fleetdm/fleet-gitops` starter repo is deprecated — scaffolded instead
via `fleetctl new` into a new repo (`fleet-homelab-gitops`), pushed to
GitHub.

- `default.yml` (repo root) — org-wide settings, including
  `org_settings.sso_settings` for Okta, global enroll secret, and
  `controls.windows_enabled_and_configured`.
- `fleets/workstations.yml` (scaffold's current layout; older docs say
  `teams/`) — a single fleet covering all my devices
  (Windows/macOS/Linux); one fleet is sufficient at this scale. The scaffold's second
  `personal-mobile-devices` fleet is deleted. Note `default.yml` containing
  `org_settings` makes the workflow delete any Fleet not defined in the repo.
- GitHub Actions workflow (from the `fleetctl new` scaffold): push to `main`
  → apply; pull request → dry-run only; nightly cron → drift correction.
  Every run first checks Fleet's `/healthz`; when the stack is torn down it
  skips with a warning instead of failing. Each `up` starts a run, so changes
  merged while the stack was down are applied after the rebuild (see Remote
  execution).
- Enroll secrets are not in Git: Fleet's GitOps excepts them by default
  (`gitops.exceptions.secrets: true`) and they are managed in Fleet.
- Repo secrets: `FLEET_URL`, `FLEET_API_TOKEN` (the GitOps-role API user),
  `FLEET_OKTA_METADATA_URL`, `FLEET_IDP_IMAGE_URL`, and `FLEET_CI_HEADER`
  (the WAF's `x-fleet-ci` value). The two Okta values are forwarded through
  the workflow's `env:` block, which only forwards `FLEET_URL` and
  `FLEET_API_TOKEN` by default.

## Logging

Two separate log streams, not one (the second is planned, plan Task 12, not built yet):

- **Server logs** (Fleet's own operational stdout/stderr) — already handled
  by the module's default `awslogs` CloudWatch driver on the ECS task.
- **Osquery result/status logs** (device telemetry — the actual data enrolled
  hosts send back) — routed via `addons/logging-destination-firehose` to
  dedicated S3 buckets (osquery-results, osquery-status, audit), not left on
  ephemeral container storage. Chosen over the simpler `stdout`-into-the-same-
  CloudWatch-group option because I want durable, queryable, longer-
  retention storage (Athena-queryable later) rather than the cheapest path.

## Budget alerts

One `aws_budgets_budget` (COST type, monthly), notifying
the configured budget-alert email address (a gitignored variable, since this repo is public) at every $10 of actual spend from $10 to $100 (ten alerts) against a
$100/mo target: well above the expected ~$15/mo (~$25 with the optional
Grafana workspace), so in practice the alerts
catch a stack left running (about $6.45 a day). Budget data refreshes only a
few times a day, so this is a within-a-day alarm, not a real-time one. Budgets
without actions are free.

## Cost

The stack is built to be torn down when not in use, so there are three
numbers: what it costs while it runs, what is left while it is down, and the
monthly average that results.

**While running** (`us-east-1` prices, matching what this stack is billed;
hourly items × 730 hours):

| Item | Rate | Per day | Per month |
|---|---|---|---|
| Aurora MySQL `db.t3.medium`, one instance | $0.082/h | $1.97 | $59.86 |
| Aurora I/O and storage (light use) | ~$0.009/h | ~$0.21 | ~$6.40 |
| NAT Gateway | $0.045/h | $1.08 | $32.85 |
| NAT Gateway data processed (light use) | $0.045/GB | ~$0.12 | ~$3.50 |
| Fargate, 0.5 vCPU and 4 GB | $0.0380/h | $0.91 | $27.75 |
| ElastiCache `cache.t4g.small`, one node | $0.032/h | $0.77 | $23.36 |
| Application Load Balancer | $0.0225/h | $0.54 | $16.43 |
| Public IPv4 addresses (NAT Gateway plus three for the load balancer) | 4 × $0.005/h | $0.48 | $14.60 |
| WAF (one Web ACL, two rules) | $7/month | $0.23 | $7.00 |
| Data transfer, CloudWatch logs (light use) | — | ~$0.08 | ~$2.40 |
| Secrets Manager (three secrets while up) | $0.40/secret/month | $0.04 | $1.20 |
| Route 53 hosted zone | $0.50/month | $0.02 | $0.50 |
| **Total** | **~$0.27/h** | **~$6.45** | **~$196** |

Fixed by the resources: everything priced per hour. Estimated from light
homelab use: Aurora I/O, NAT data, data transfer and logs, which grow with
enrolled hosts and traffic. Not in the total yet: Firehose and S3 for osquery
logs (about $1/mo at 10 hosts, once plan Task 12 is built) and SES (cents).
The public IPv4 charge, which AWS added in 2024, is easy to miss: it costs more
than the WAF.

**While torn down:** about **$1.40/mo (about $0.05/day)**. What stays: the
Route 53 zone ($0.50), two secrets (the Fleet server key and the MDM secret,
$0.40 each), the two newest Aurora teardown snapshots (storage for a small
database, cents), and the S3 buckets (state, software installers, IdP logo;
cents). Free: the ACM certificate, the SES identity and the budget. Okta's
Free Plan and GitHub Actions on public repos cost nothing.

**Planned additions** (plan tasks not built yet):

| Addition | Task | When it bills | ~$/month |
|---|---|---|---|
| Amazon Managed Grafana, one admin (optional) | 17 | Always on | $9.00 |
| Grafana's CloudWatch queries (`GetMetricData`, $0.01 per 1,000 metrics, never in the free tier) | 17 | Always on: ~5 alert rules every 5 minutes ≈ 43,000 metrics | ~$0.50 |
| SNS email for Grafana alerts | 17 | Per email; the first 1,000 a month are free | $0 |
| Firehose and S3 for osquery logs (Firehose $0.029/GB, each record rounded up to 5 KB) | 12 | Only while hosts check in, so only while up | <$1 |
| Activities webhook: API Gateway, Lambda, DynamoDB | 19 | Always on, per request; Lambda and DynamoDB stay in the free tier at this volume | ~$0 |
| End-user SSO (a second Okta app); Apple push certificate | 20, 8B | — | $0 |

Watch two Grafana costs: evaluating alert rules every minute instead of every
five roughly quadruples the query cost (~$2/mo), and a dashboard left open
and auto-refreshing every minute adds about $5–6/mo in queries. Each extra
active Grafana user adds $9 (editor) or $5 (viewer) a month.

**Average:** at roughly one weekend a month of use (~7% uptime, about 50
hours):
- **Stack only:** 50 × $0.27 + $1.40 ≈ **$15/mo**, the number that matters for
  this deployment.
- **With everything planned**, Grafana included: the always-on part rises to
  about $11/mo (about $0.37/day torn down), so 50 × $0.27 + $11 ≈ **$25/mo**.
  The hourly cost while up stays about $0.27, since the additions are almost
  all fixed monthly charges; left running for a whole month, everything comes
  to about $207.

Each extra hour up adds about $0.27; each full day left running adds about
$6.45.

This is essentially the original, pre-cost-cut sizing — see the "Why the
reversal" note above. It only makes sense given the intermittent usage
pattern; **do not run this continuously** without revisiting sizing.

### Teardown tooling (`up` and `down`)

My actual usage pattern is intermittent — evenings/weekends only —
so **`up`/`down` (full teardown) is the only mode**. There is no
idle/resume pause: Redis, the ALB, WAF and the NAT Gateway have no
"stopped" state, so pausing only Fargate and Aurora compute saves little,
and only `up`/`down` removes their cost. No automatic scheduling
(Lambda/EventBridge) either: `up` and `down` are always started deliberately,
from my laptop (`scripts/up.sh`, `scripts/down.sh`) or from the infra repo's
GitHub Actions workflow (see Remote execution), which runs the same scripts.

**How long it takes** (measured on CI runs): `up` about **22 minutes**, `down`
about **18–20 minutes**. Aurora dominates both: restoring the cluster and
creating its instance on the way up, the snapshot and the deletion on the way
down; the NAT Gateway and the migrations task add a few minutes.

**`down`** (`scripts/down.sh`, asks for `destroy` to confirm; in CI the
`confirm` input):
1. Takes an Aurora **cluster** snapshot, `fleet-homelab-teardown-<time>`, and
   waits until it is available.
2. Runs a targeted `terraform destroy` of the expensive part: `module.fleet`
   (VPC with the NAT Gateway, Aurora, Redis, ALB, ECS), the migrations runner,
   the WAF Web ACL and the DNS alias record.
3. Deletes the Container Insights log group, which AWS re-creates as the
   cluster shuts down (left behind, it breaks the next `up`).
4. Deletes older teardown snapshots, keeping the newest two.
5. Checks that no ECS cluster, Aurora, Redis, load balancer, NAT Gateway,
   tagged VPC or WAF Web ACL is left, and fails if one is.

**`up`** (`scripts/up.sh`):
1. Finds the newest teardown snapshot through the AWS API (so it works the
   same on a fresh CI runner) and restores Aurora from it; `--fresh` starts
   with an empty database instead.
2. Plans and applies, retrying once on a known IAM propagation race
   (`scripts/tf-apply.sh`).
3. Waits for the ECS service to settle and checks `/healthz` and `/` (200 on
   `/` means the data came back; a redirect to `/setup` means an empty
   database).
4. Starts a run of the GitOps repo's workflow, so Fleet's configuration from
   `main` is applied straight after the rebuild.

**What survives a teardown**, and why:
  - **The database**, through the snapshot: hosts, policies, query results,
    users (including the break-glass admin and its MFA setting) and Apple MDM
    state.
  - The Fleet server's private-key secret (used to encrypt sensitive data at
    rest in the DB) is created and owned outside `module.fleet`, specifically
    so destroying that module doesn't destroy the key — a rebuilt server
    with a *different* key couldn't decrypt data restored from the Aurora
    snapshot.
  - `module.mdm` (the `fleet-scep` secret holding the Windows WSTEP pair) is
    deliberately **not** in `down`'s destroy targets — losing it would lose
    access to BitLocker keys escrowed under that certificate.
  - The software-installers bucket lives outside `module.fleet` (the module's
    own bucket is `force_destroy = true` and would be wiped on teardown);
    the task role is granted access via `extra_iam_policies`.
  - The Route 53 zone and ACM certificate (so the nameserver delegation and
    the certificate stay valid), the SES identity (avoids re-verification),
    the Terraform state bucket, the IdP logo bucket and the budget.
  - Redis needs none of this — it's cache/live-query pub-sub, not durable
    app state, so losing it on teardown is fine.
  - The VPC (including NAT Gateway) is destroyed and recreated each cycle
    too — it's part of the same root module call as everything else, so
    `-target=module.fleet` handles it with no separate targeting. Nothing
    durable lives inside it.

## Remote execution (GitHub Actions, OIDC, GitHub-hosted runners)

`up`/`down` are triggered via a `workflow_dispatch` GitHub Actions
workflow in the infra repo (pull requests run `plan`; see below), runnable from GitHub's UI, its mobile app, or
`gh workflow run` from anywhere — not tied to my laptop. The infra
repo is **public** (a portfolio piece), so the workflow runs on
**GitHub-hosted runners** (pinned to `ubuntu-24.04`), which are free and unlimited
for public repos. A self-hosted runner (the original design: an LXC
container on my Proxmox server) was dropped because GitHub
explicitly warns against self-hosted runners on public repos — a fork pull
request can modify the workflow and execute code on the runner, which would
be a machine on the home network. A hosted job is a throwaway VM with no
route to the LAN, and everything Terraform touches (AWS, Cloudflare, Fleet)
is a public API, so nothing is lost. GitHub's OIDC identity token is minted
server-side either way, so the "no long-lived AWS keys" property is
unchanged.

**Public-repo security model.** Only the owner has write access, so only
the owner can merge, approve, dispatch workflows or push branches. Anyone
can open a PR from a fork, but fork PRs get no Actions secrets and a
read-only token, and outside-collaborator workflow runs require approval.
Secret scanning with push protection is on, Actions permissions are
read-only by default, third-party actions are pinned to commit SHAs, and
`main` is protected by a ruleset with no bypass, not even for the owner:
every change, docs included, goes through a pull request whose
`terraform-lint` and `terraform-plan` checks pass (the GitOps repo likewise
requires its `fleet-gitops` check). Dependabot keeps actions and providers
current, and its pull requests get a plan too. Nothing personal or secret is committed:
the commit author is the GitHub noreply address, and the budget-alert email,
license key and Cloudflare token live only in gitignored `terraform.tfvars`
and GitHub secrets. The AWS trust policy is the second lock: the apply role
only trusts `workflow_dispatch` on `main` in this repo's immutable ID.

**The trust policy uses GitHub's newer immutable subject-claim format**
(`repo:OWNER@OWNER-ID/REPO@REPO-ID:...`), not the older name-based one —
checked during execution: any repository created after
July 15, 2026 gets this format automatically (verified against GitHub's
own changelog), and this repo is created fresh. The numeric owner/repo IDs
don't exist until the repo is actually pushed to GitHub, which is why the
infra repo gets pushed to GitHub as this task's *first* step rather than
its last — an ordering an earlier draft of this design got backwards.

Deliberately a
manual trigger, not auto-apply-on-push: an infra `destroy` is far more
consequential than a Fleet config sync, and this deployment's shape (mostly
torn down) doesn't suit "apply whenever something merges" the way an
always-on service would. Every `.tf` change still gets reviewed before it
takes effect: opening a PR runs `terraform plan` and posts the output as a
comment (mirroring the dry-run behavior the GitOps repo already has for
Fleet config), so merging to `main` is always an informed decision — the
apply itself just waits for the next manual `up` trigger rather than firing
immediately. Two IAM roles serve this, not one: an **apply role**
(assumable only by a `workflow_dispatch` run on `main`) for `up`/`down`,
and a **read-only plan role** (assumable only from the `pull_request` context)
for the PR checks — a PR workflow runs the file from the PR's own branch, so it
gets no write access. The apply role is scoped by AWS service (EC2/VPC, RDS,
ElastiCache, ECS + Application Auto Scaling, ELB, WAFv2, CloudWatch/Logs, SES,
Route 53, ACM, Firehose, Budgets), with Secrets Manager limited to `fleet*`
secrets, S3 limited to this project's buckets (`fleet-homelab-*` and the ECS
module's `fleet-software-installers-*`), KMS use limited by `kms:ViaService`,
and IAM *write* limited to role/policy names the stack creates (`fleet*`, plus
`terraform-*` — the AWS provider's auto-generated name for the addons' unnamed
Firehose/SES/MDM roles and policies). `iam:PassRole` is limited to the three
consuming services. Explicit `Deny`s close the escalation paths a service-level
allow list leaves open: changing either CI role or its policies (so changes to
`oidc.tf` are applied locally by an admin, never by CI), `sts:AssumeRole`
(same-account role trust needs no identity-policy allow), attaching a
fully-broad managed policy, and `ec2:RunInstances` (the stack is Fargate-only).
No IAM-user or OIDC-provider write actions are granted at all. An independent
review found the first draft — broad IAM write on `*` with only
`AttachRolePolicy` denied — let a compromised token rewrite its own policy or
any role's trust policy and become admin; the above closes that.

This is *scoped*, not formally least-privilege: within each service, actions
are still broad (`rds:*`, `ecs:*`), and one residual remains — a compromised
apply token can still create a new `fleet*`/`terraform-*` role and run code as
it in an ECS task it also defines. Closing that needs a permissions-boundary
condition on every role it creates, and Fleet's modules expose no
`permissions_boundary` input. It can also read the `fleet*` secrets and the
state. The mitigation that fits is the trust policy — only a manual dispatch on
`main` of this single-owner repo can assume the role — with an optional
stronger gate (a GitHub Environment with a required reviewer) not built here.
It would need revisiting in any shared or production account.

**Starting the GitOps run after `up`.** A workflow's own token is limited to
its repo, so the infra workflow cannot start the GitOps repo's workflow with
it. A private **GitHub App** fills that gap: created on the owner's account,
with one permission (Actions: read and write) and installed on the GitOps repo
only. Before `up`, the job uses the app's client ID and private key (two
secrets) to get an installation token limited to that repo and Actions write,
revoked when the job ends. Chosen over a fine-grained personal access token,
which expires and is tied to a user; the app's key does not expire and can do
nothing beyond starting workflows in one repo. The step is best effort: if it
fails, the rebuild still succeeds with a warning, and the nightly GitOps run
catches up.

## Dashboard (Grafana) — optional

*Planned (plan Task 17), not built yet. Redesigned 2026-10-10 from a Proxmox
container to Amazon Managed Grafana.*

**Amazon Managed Grafana (AMG)**, in its own Terraform root (`grafana/`, own
state key, applied locally like `okta/`). It is **optional**: the main stack,
`up`/`down` and CI never reference it, so anyone reusing this repo can leave
it out by not applying that root. The Okta side is optional the same way
(created only when the workspace endpoint is given to `okta/`).

- **Always on.** AWS bills per active user per month with a one-editor minimum
  per workspace, about **$9/month** for a single admin, whether or not the
  Fleet stack is up. It is not torn down: that would not reliably save money
  and would lose anything not in code. While the stack is down, CloudWatch
  history (15 months) stays visible and the Fleet panels show no data. API keys
  and service accounts are billed like users, so the design uses none (panels
  are built by hand, which suits the goal of learning Grafana).
- **No stored AWS credentials.** The workspace reads CloudWatch through an IAM
  role (`fleet-homelab-grafana`). This replaces the earlier design's static
  CloudWatch access key, which was the plan's one long-lived AWS credential,
  and its SES-SMTP IAM user.
- **Sign-in through Okta**, with the same rule as Fleet: two groups (Grafana
  Admins, Grafana Viewers) assigned to an Okta "Amazon Managed Grafana" app,
  membership set by hand, a role attribute that maps to Admin or Viewer, and
  Okta refusing anyone in neither group.
- **Data sources:** CloudWatch (ALB, ECS, Aurora and Redis metrics) and Fleet's
  REST API through the Infinity plugin (installed with AMG's plugin
  management), using a read-only API-only Fleet user's token. That token is a
  Fleet credential, read-only and revocable, not an AWS one.
- **Alerting:** AMG's contact points are SNS, PagerDuty, Slack and VictorOps
  (no email/SMTP), so alerts go to an SNS topic with an email subscription.
  Rules treat no data as OK, because a torn-down stack is the normal state, and
  a "stack left running" rule catches forgotten teardowns hours before the
  budget alert would.

**Up/down status board first**: the dashboard's main job is showing at a
glance whether each part of the Fleet stack is up — a Fleet `/healthz`
probe, ALB healthy/unhealthy targets, Fargate running task count, and Aurora
and Redis activity (no data = down). Because the stack is torn down most of
the time by design, a red board usually means "torn down on purpose".

## Repositories

- **`fleet-homelab-infra`** (this repo) — Terraform config referencing the
  `fleet-terraform` root module and addons, the separate `okta/` root for the
  Okta side and the optional `grafana/` root (both applied locally), the
  `up`/`down` operational scripts, and one GitHub Actions workflow
  (`terraform.yml`: `lint` and `plan` on pull requests, `apply` for on-demand
  up/down) with a shared setup action, that drives them remotely.
- **`fleet-homelab-gitops`** — `fleetctl new` scaffold, pushed to its own
  GitHub repo, driving Fleet server config via GitHub Actions.
