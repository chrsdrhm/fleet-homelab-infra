# Fleet Premium on AWS — homelab deployment design

Date: 2026-09-17
Status: approved, ready for implementation plan

## Goal

Deploy a "real" Fleet Premium instance into my own
AWS account: publicly accessible over HTTPS, federated to Entra ID for SSO,
managed via Fleet GitOps, and reasonably secure — while minimizing recurring
AWS cost, since this is for personal homelab learning, not production scale.

## Non-goals (explicitly deferred)

- **Okta SSO** — I don't have an Okta tenant yet. Entra ID is the primary
  IdP now; Okta can be added later as a second IdP exercise if a tenant
  becomes available through work.
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

- **Primary IdP: Entra ID**, chosen because I already have this tenant;
  not Entra-specific in any way that locks the design in — Fleet's SSO is
  generic SAML, so switching to Okta later is a GitOps YAML change
  (`idp_name`, `metadata_url`) plus a new Okta app registration, no
  infrastructure change. The one thing that *would* need redoing is the
  group-to-role mapping below, since Okta and Entra represent group
  membership differently in a SAML assertion.
- **JIT provisioning + group-based role mapping** (Premium): SAML SSO
  configured via Fleet GitOps `org_settings.sso_settings` (`entity_id`,
  `idp_name`, `metadata_url`, `enable_sso_idp_login`, `enable_jit_provisioning`).
  With JIT provisioning on, Fleet accounts are created automatically on first
  SSO login rather than needing to be pre-created. The role a JIT-provisioned
  account gets comes from a custom SAML attribute, `FLEET_JIT_USER_ROLE_GLOBAL`
  (accepted values: `admin`, `maintainer`, `observer`, `observer_plus`,
  `technician`, `null`) — this is entirely an IdP-side mechanism, not a
  Fleet-side mapping table: an Entra security group ("Fleet Admins") is
  created and assigned the `admin` app role on the Entra application (and a
  "Fleet Observers" group the `observer` role; membership of both comes from
  two Terraform lists, and a plan-time check rejects anyone in both, because
  Fleet silently takes the last role value it is sent). A claims-mapping
  policy emits each user's assigned app role as the attribute. The whole Entra side is Terraform
  (`entra/`, separate state, applied locally by a tenant admin, never from CI). Per-team role mapping
  (`FLEET_JIT_USER_ROLE_FLEET_<team_id>`) is possible later but needs the
  numeric team ID Fleet assigns once the "Workstations" team exists — a
  deliberate follow-up, not part of this pass, to avoid a chicken-and-egg
  with team creation.
- **Break-glass account**: one Fleet global admin created via
  `fleetctl setup` — Fleet's first-run bootstrap, immediately after the first
  deploy (a fresh Fleet has no users, and `fleetctl user create` needs an
  existing session) — password auth, not SSO-linked, *before* SSO is
  enabled. Fleet allows password-auth and SSO-auth users to coexist, so this
  account stays reachable at `/login` after SSO is turned on. Credentials go
  in my personal password manager — deliberately *not* AWS Secrets
  Manager, so an IAM/AWS-side problem can't also lock out the break-glass
  path. JIT provisioning has no effect on this account since it isn't
  SSO-authenticated. **MFA (optional, recommended, enabled last)**: it's the one account
  protected by a password alone (SSO users get Entra's own MFA), so it can get
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
`terraform destroy`/`apply` cycles (see Pause tooling below), not
continuously. Under that pattern, the delta between the cheap and the
"real"/recommended sizing shrinks to a few dollars a month, so there's
little reason to carry the operational downsides of the cheapest tier
(RDS memory headroom risk, no defense-in-depth on the network egress path)
just to save single-digit dollars. High-availability features (replicas,
failover, redundant tasks) are a separate, deliberately-skipped axis — see
Non-goals above.

| Component | Decision |
|---|---|
| VPC | 3 AZs (module requirement for subnet groups); public, private, database, and elasticache subnets. **NAT Gateway restored** (single gateway, module default) — Fargate now runs in a private subnet with egress via NAT, not a public subnet. |
| Database | **Aurora MySQL** via the root module's built-in `rds_config`, `db.t4g.medium`, single instance (`replicas = 1` — the total instance count in the root module, so one writer and no reader; see Non-goals), 7-day backup retention |
| Cache | ElastiCache Redis, `cache.t4g.small`, `cluster_size = 1` (no failover) |
| Compute | ECS Fargate, `cpu = 512`, `mem = 4096` (4GB required for vulnerability scanning, which stays **on**), `autoscaling.min_capacity = 1`, `max_capacity = 2`. Task now in a **private subnet**, NAT for egress, security group still only allows inbound from the ALB's security group. |
| Image | `fleetdm/fleet` (or the `quay.io` mirror to avoid Docker Hub rate limits) |
| ALB | Public, HTTPS via ACM (DNS-validated), target group → Fargate task |
| WAF | `addons/waf-alb` in `blocklist` mode, attached to the ALB — this addon is geo/IP-based (default blocked-country list), not an AWS Managed Rule Group; it does not provide signature-based protection against SQLi/XSS-style attacks |
| MDM | `addons/mdm` — one `fleet-scep` secret holding the Windows WSTEP pair (Apple MDM is configured through the Fleet UI, `enable_apple_mdm = false`). Two-phase: secret created empty, populated, then wired into the task (an empty secret referenced by the task would fail to start). **Excluded from teardown** — see Pause tooling. |
| Monitoring | No standalone CloudWatch-alarm addon — superseded by Grafana's own native alerting on the same metrics (see Dashboard), delivered via a dedicated SES-SMTP IAM user |
| Email | `addons/ses` — outbound mail for invites and break-glass password reset |
| Secrets | AWS Secrets Manager: Aurora password (module-managed), the Windows WSTEP pair (module-managed secret, persisted across teardown), Fleet server private key (created **outside** the Fleet module specifically so it survives `module.fleet` being destroyed — see Pause tooling). AWS-managed KMS keys (no CMKs) throughout. |
| License | `FLEET_LICENSE_KEY` supplied as an environment variable / Secrets Manager entry to the ECS task |
| Terraform state | S3 backend with native locking (`use_lockfile = true`) — no DynamoDB table; `dynamodb_table` was deprecated in Terraform 1.11 in favor of S3's own conditional-write locking |

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
  `org_settings.sso_settings` for Entra, global enroll secret, and
  `controls.windows_enabled_and_configured`.
- `fleets/workstations.yml` (scaffold's current layout; older docs say
  `teams/`) — a single fleet covering all my devices
  (Windows/macOS/Linux) with its enroll secret under `settings.secrets`; one
  fleet is sufficient at this scale. The scaffold's second
  `personal-mobile-devices` fleet is deleted. Note `default.yml` containing
  `org_settings` makes the workflow delete any Fleet not defined in the repo.
- GitHub Actions workflow (from the `fleetctl new` scaffold): push to `main`
  → apply; pull request → dry-run only; nightly cron → drift correction.
- Repo secrets: `FLEET_URL`, `FLEET_API_TOKEN` (the GitOps-role API user),
  `FLEET_ENTRA_METADATA_URL`, and the enroll secrets — the last three must
  also be added to the scaffolded workflow's `env:` block, which only
  forwards `FLEET_URL` and `FLEET_API_TOKEN` by default.

## Logging

Two separate log streams, not one:

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
$100/mo target — comfortable headroom above the ~$84–86/mo estimate before
alerting. First AWS Budget is free (2 free per account).

## Cost

Target, `us-east-1`, running continuously:

| Item | $/mo |
|---|---|
| Aurora MySQL `db.t4g.medium`, single instance | ~$55 |
| ElastiCache `cache.t4g.small`, 1 node | ~$23 |
| Fargate (512 CPU / 4096MB, vuln scanning on) | ~$27 |
| NAT Gateway | ~$33 |
| ALB | ~$17 |
| WAF | ~$6–8 |
| Secrets Manager (~5 secrets) | ~$2 |
| Route 53 hosted zone | ~$0.50 |
| CloudWatch (logs only — alerting now happens in Grafana, not as billed CloudWatch alarms) | ~$3 |
| SES | ~$0.50 |
| Firehose + S3 (osquery/audit logs, 10-host volume) | ~$1 |
| AWS Budgets | $0 (within free tier) |
| **Total (always on)** | **~$169–171/mo** |

This is essentially the original, pre-cost-cut design — see the "Why the
reversal" note above. It only makes sense given the intermittent usage
pattern below; **do not run this continuously** without revisiting sizing.

### Pause tooling (manual, two tiers)

My actual usage pattern is intermittent — evenings/weekends only —
so **`up`/`down` (full teardown) is the primary mode**, not an occasional
extra. `idle`/`resume` still exists for a same-session pause, but doesn't
do much here since Redis, ALB, WAF, and (now) NAT Gateway have no "stopped"
state — only `up`/`down` actually removes their cost.

- **`idle` / `resume`** — set the ECS autoscaling target to 0/0 (otherwise
  its min of 1 scales the service straight back up) and desired count to 0,
  and stop the Aurora cluster; bring back up in seconds (resume restores
  min 1 / max 2). A `terraform apply` while idled re-registers min 1 and
  wakes the service. Ceiling savings ~$66–70/mo (Fargate's
  $27 + Aurora compute's ~$53), since Redis + ALB + WAF + NAT
  (~$79–81/mo) keep billing regardless. Note: AWS force-restarts a stopped
  RDS/Aurora instance after 7 days if left stopped that long. Minor,
  secondary tool given the primary pattern below.
- **`up` / `down`** — full `terraform apply` / `terraform destroy` of the
  VPC+compute+db+cache+alb stack (now including the VPC/NAT Gateway, which
  wasn't torn down in the earlier no-NAT design), keeping the Route 53
  hosted zone, Terraform state backend (S3, natively-locked), MDM secrets,
  the software-installers bucket, the SES identity (free at rest, avoids
  re-verification each session), Firehose/S3 log buckets, and the budget
  alert intact. Gets cost down to
  ~$1–2/mo while torn down. ~15–20 min turnaround to bring back up (Aurora +
  NAT Gateway provisioning dominate — NAT alone takes a few minutes to
  become available).

  At roughly one weekend a month of actual use (~7% uptime), this averages
  to **~$12–15/mo** rather than the ~$169–171/mo always-on figure — this is
  the number that actually matters for this deployment, not the always-on
  total.

  **Teardown preserves actual state, not just infrastructure:**
  - `down` takes an Aurora **cluster** snapshot (`aws rds
    create-db-cluster-snapshot`) immediately before destroying the cluster;
    `up` can restore from it (via `rds_config.snapshot_identifier`) instead
    of creating an empty database, so hosts, policies, query results, and
    user accounts survive a teardown/rebuild cycle.
  - The Fleet server's private-key secret (used to encrypt sensitive data at
    rest in the DB) is created and owned outside `module.fleet`, specifically
    so destroying that module doesn't destroy the key — a rebuilt server
    with a *different* key couldn't decrypt data restored from the Aurora
    snapshot.
  - `module.mdm` (the `fleet-scep` secret holding the Windows WSTEP pair) is
    deliberately **not** in `down`'s destroy targets — losing it would lose
    access to BitLocker keys escrowed under that certificate. (Apple MDM state
    lives in the database and survives via the Aurora snapshot.) Left
    provisioned, this costs ~$0.40/mo while torn down.
  - The software-installers bucket lives outside `module.fleet` (the module's
    own bucket is `force_destroy = true` and would be wiped on teardown);
    the task role is granted access via `extra_iam_policies`.
  - Each teardown leaves a manual Aurora snapshot that bills until deleted;
    `down` prints a prune reminder.
  - Redis needs none of this — it's cache/live-query pub-sub, not durable
    app state, so losing it on teardown is fine.
  - The VPC (including NAT Gateway) is destroyed and recreated each cycle
    too — it's part of the same root module call as everything else now
    (see AWS infrastructure above), so `-target=module.fleet`
    (plus migrations, and the WAF Web ACL) handles it alongside Aurora/Redis/ALB/ECS, no separate
    targeting needed. Cheap and fast relative to Aurora/ALB, and nothing durable
    lives inside it (Route 53 and ACM are independent of the VPC).

No automatic scheduling (Lambda/EventBridge) — `up`/`down`/`idle`/`resume`
are always deliberately triggered, never time-based. What changes is *where
from*: not my laptop except for testing (see Remote execution
below).

## Remote execution (GitHub Actions, OIDC, GitHub-hosted runners)

`up`/`down`/`plan` are triggered via a `workflow_dispatch` GitHub Actions
workflow in the infra repo, runnable from GitHub's UI, its mobile app, or
`gh workflow run` from anywhere — not tied to my laptop. The infra
repo is **public** (a portfolio piece), so the workflow runs on
**GitHub-hosted runners** (`ubuntu-latest`), which are free and unlimited
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
`main` is protected by a ruleset. Nothing personal or secret is committed:
the commit author is the GitHub noreply address, and the budget-alert email,
license key and Cloudflare token live only in gitignored `terraform.tfvars`
and GitHub secrets. The AWS trust policy is the second lock: the apply role
only trusts `workflow_dispatch` on `main` in this repo's immutable ID.

**The trust policy uses GitHub's newer immutable subject-claim format**
(`repo:OWNER@OWNER-ID/REPO@REPO-ID:...`), not the older name-based one —
checked during execution, not assumed: any repository created after
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
(assumable only by a `workflow_dispatch` run on `main`) for `up`/`down`/`plan`,
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
`main` of a private single-user repo can assume the role — with an optional
stronger gate (a GitHub Environment with a required reviewer) not built here.
It would need revisiting in any shared or production account.

## Dashboard (Grafana)

A Grafana instance on Proxmox, in its own LXC container — no new AWS cost, and it stays reachable even while the
Fleet stack itself is torn down, since every one of its data sources is a
public endpoint, not anything inside the VPC. Grafana itself never stores
or ingests this data — it's purely a query-and-visualize layer, issuing
each data source's query live on every dashboard load/refresh; only the
panel/dashboard *definitions* live in Grafana's own database.

- **CloudWatch** — ALB/ECS/Aurora/Redis metrics, visualized *and* alerted
  on: Grafana's own native alerting (OSS, not Enterprise-gated) defines
  alert rules directly against these same CloudWatch queries, replacing
  what an earlier draft had as a separate CloudWatch-alarms-plus-SNS design.
  Notification email goes out through Grafana's own SMTP config, using a
  second, send-only SES IAM user (distinct from Fleet's own SES sending
  path) — one monitoring system instead of two. Reached directly over the
  public CloudWatch API; no VPC access needed.
- **Fleet's REST API**, via Grafana's Infinity plugin (queries arbitrary
  JSON/REST endpoints — not bundled with Grafana OSS core, installed
  separately) — host counts and platform breakdown, policy pass/fail counts,
  and vulnerability data (Premium `charts/cve` endpoint). Reached over
  Fleet's own public HTTPS endpoint with a dedicated read-only (`observer`)
  API-only Fleet user's token (non-expiring, unlike a `fleetctl login`
  session token).
- **Entra ID, via Microsoft Graph** (a second Infinity data source instance)
  — user/sign-in activity, "Fleet Admins" group membership, and
  Entra-registered devices cross-referenced against Fleet's own enrolled
  hosts. Built as the Entra-specific instance of a pattern meant to port to
  Okta later, not an Entra-only design: a dedicated least-privilege App
  Registration with application (not delegated) Graph permissions, admin-
  consented since I administer this tenant directly, authenticating
  via OAuth2 client credentials. Sign-in activity specifically requires
  Entra ID P1/P2 (not available on Free) — verified against Microsoft's own
  docs; group membership and device listing have no such gate.

**Up/down status board first**: the dashboard's main job is showing at a
glance whether each part of the Fleet stack is up — a Fleet `/healthz`
probe, ALB healthy/unhealthy targets, Fargate running task count
(Container Insights is on by default in the Fleet ECS cluster), and Aurora
and Redis activity (no data = down). Because the stack is torn down most of
the time by design, a red board usually means "torn down on purpose", and
Grafana only displays status; it sends no notifications.

The primary goal stated for the Grafana work overall was learning Grafana
itself, so the dashboard panels are deliberately left for hands-on building
rather than fully pre-built — the plan sets up the container and all three
data source connections, not the finished dashboard.

**Two deliberate exceptions to this whole plan's "no long-lived
credentials" pattern** live here, both for the same underlying reason —
Grafana runs outside both AWS and Entra with no equivalent to GitHub
Actions' OIDC federation available to it: a static AWS IAM access key
(CloudWatch read-only, Task 17) and an Entra App Registration client secret
(Task 18). Both scoped to read-only/least-privilege actions to bound what
either is worth if it ever leaked.

## Repositories

- **`fleet-homelab-infra`** (this repo) — Terraform config referencing the
  `fleet-terraform` root module and addons, the
  `idle`/`resume`/`up`/`down` operational scripts, and the two GitHub
  Actions workflows (on-demand apply/destroy, PR plan checks) that drive
  them remotely.
- **`fleet-homelab-gitops`** — `fleetctl new` scaffold, pushed to its own
  GitHub repo, driving Fleet server config via GitHub Actions.
