[![LinkedIn](https://img.shields.io/badge/LinkedIn-Connect-blue?logo=linkedin)](https://www.linkedin.com/in/chrsdrhm/)

# fleet-homelab-infra

Terraform for a **Fleet Premium** deployment on AWS, built as a homelab project for learning and experimentation.

> **This is a personal learning project, not production guidance.** It runs in my own AWS account, is torn down when I'm not using it, and is here so I can work through the tooling in the open. Fleet's own configuration (SSO, fleets, policies) lives in a separate repo: [`fleet-homelab-gitops`](https://github.com/chrsdrhm/fleet-homelab-gitops). Take ideas from this repo, but don't treat it as a hardened reference architecture.

## What this is

[Fleet](https://fleetdm.com) is an open-source device management and osquery platform. I'm standing up a real, publicly reachable Fleet instance to learn how the pieces fit together:

- **Infrastructure:** Fleet's own [`fleet-terraform`](https://github.com/fleetdm/fleet-terraform) root module (VPC, Aurora MySQL, Redis, ALB, ECS Fargate), pinned to a release tag rather than reimplemented.
- **DNS and TLS:** a Route 53 hosted zone for a subdomain, delegated from Cloudflare (also managed in Terraform), with an ACM certificate.
- **Identity (optional):** Okta SAML SSO with just-in-time provisioning and group-based roles, plus a break-glass admin. Nobody gets a Fleet role unless they are in one of the two Okta groups. It's a separate Terraform root, so you can leave it out and use password logins instead (see below).
- **GitOps:** Fleet's configuration managed from a separate repo with `fleetctl gitops`.
- **CI:** Terraform run from GitHub Actions using OIDC, so there are no long-lived AWS keys in GitHub.
- **Observability (optional):** an Amazon Managed Grafana dashboard with alerts, showing infrastructure health and Fleet asset data. It's a separate Terraform root, so you can leave it out; it stays up all the time for about $10 a month.

## Cost

Left running, the stack would cost about **$7 a day, or about $200 a month** (roughly $0.25 an hour): mostly Aurora, the NAT Gateway, Fargate, Redis, the load balancer, and the public IPv4 addresses of the load balancer and NAT Gateway. That's too much for a homelab, so it's built to be **torn down when I'm not using it and rebuilt when I am**, without starting over: the database, users, hosts and settings come back each time (see [Teardown and rebuild](#teardown-and-rebuild)). Torn down, it costs about **$2 a month**. At roughly a weekend a month of use (about 50 hours), that averages out to around **$15 a month**. The optional Grafana dashboard stays up all the time and adds about **$10 a month**, so about **$25 a month** with it. A $100 AWS Budget emails me at every $10 of spend, mainly to catch a stack I forgot to tear down. The [design spec](docs/specs/fleet-homelab-aws-design.md#cost) has the per-item breakdown.

## Teardown and rebuild

**A rebuilt Fleet picks up where you left off: the same users, hosts, settings and SSO.** Nothing starts fresh. Two scripts do it, and the same scripts run from my terminal or from GitHub Actions:

- **`scripts/down.sh`** (about 20 minutes) snapshots the Aurora database, destroys the expensive part of the stack (VPC and NAT Gateway, Aurora, Redis, load balancer, ECS, WAF), keeps the two newest snapshots, and checks that nothing billable is left.
- **`scripts/up.sh`** (about 20 minutes) finds the newest snapshot, rebuilds the stack from it, waits until Fleet answers, and then starts a run in the GitOps repo so the latest Fleet configuration is reapplied, including any changes merged there while the stack was down.

The teardown only removes the expensive parts; everything that holds state stays. The database is snapshotted before it's deleted and restored on the way back up, and Apple MDM's push certificate and keys are stored in it. The Fleet server key that encrypts it, the Windows MDM certificate (in Secrets Manager), the software-installers bucket, DNS, the TLS certificate and the email sending identity are never torn down.

## Sized for a homelab

Fleet's Terraform module is used as published (pinned to a release tag), with smaller inputs. Its defaults and Fleet's own [reference architectures](https://fleetdm.com/docs/deploy/reference-architectures) are built for thousands of hosts, with database replicas, three Redis nodes and several Fleet servers. This homelab has about ten hosts, so it runs one Fleet server (autoscaling to two at most), one Aurora instance of the size Fleet recommends for up to 5,000 hosts, and one Redis node. That's plenty of performance at this scale; what it gives up is failover, which a homelab doesn't need, since the recovery plan is a rebuild from the snapshot. It's also most of why the stack costs about $200 a month left running instead of several times that. The [design spec](docs/specs/fleet-homelab-aws-design.md#sizing-compared-with-fleets-defaults-and-guidance) has the side-by-side comparison.

## Identity: an Okta free tenant

Single sign-on uses an **Okta Workforce Identity free trial**, which turns into Okta's **Free Plan** after 30 days (up to 10 users, SSO and MFA, no support, $0). Okta can close an org after 45 days of inactivity, so I sign in at least once a month. The Okta side (the Fleet SAML app, two groups that map to Fleet roles, and the role attribute) is Terraform in [`okta/`](okta/), applied from my terminal with an Okta API service app that signs in with a private key. Who is in each group is set by hand in Okta, never by Terraform.

**Okta is optional.** Fleet runs fine without single sign-on: users then sign in with a password, starting with the admin you create on first setup. I use Okta because it makes the lab more like a real deployment, where people sign in through the company's identity provider and get their Fleet role from it. To leave it out, don't apply `okta/`, and turn SSO off in the GitOps repo's `default.yml` (its README says how). Fleet's SSO is standard SAML, so any other SAML identity provider works too; you'd configure that one by hand or in its own Terraform. The small public bucket for the login button's logo (`idp_logo.tf`) is only for SSO, and you can delete it.

## Repo layout

| Path | What it is |
|---|---|
| `*.tf` | The AWS and Cloudflare Terraform configuration |
| `okta/` | Optional. The Okta side: SAML app, groups and role attribute (its own Terraform root, applied locally) |
| `grafana/` | Optional. The Amazon Managed Grafana workspace, its IAM role and alert topic (its own Terraform root, applied locally) |
| `scripts/` | `up.sh`, `down.sh` and `tf-apply.sh` (apply with one known retry) |
| `.github/` | The CI workflow (lint, plan, apply), its shared setup action, Dependabot and CODEOWNERS |
| `docs/specs/` | Design spec: decisions, cost and how teardown works |
| `docs/plans/` | The implementation plan, including problems found and fixed while running it |
| `example.tfvars`, `backend.example.hcl` | Placeholder values; real values live in gitignored `terraform.tfvars` and `backend.hcl` |

## Security notes

- **No AWS keys in GitHub.** CI reaches AWS through OIDC. Rebuild and teardown use a role that only manual runs on `main` can assume; pull-request plans use a separate read-only role.
- **No shortcuts to `main`.** Every change goes through a pull request whose lint and plan checks pass, with no bypass, including for me. Plans posted on pull requests are masked, since comments on a public repo are public.
- **Found a problem?** Please [report it privately](https://github.com/chrsdrhm/fleet-homelab-infra/security/advisories/new) through this repo's **Security** tab instead of opening a public issue.

## Built with AI assistance

I planned and built this with [Claude Code](https://claude.com/claude-code). The design decisions, the account it runs in, and the review of what gets applied are mine; much of the plan text, and a lot of the fact-checking against upstream module source, were done with the assistant. The plan records where an early draft was wrong and got corrected, so those mistakes stay visible instead of being edited out.

## License

[MIT](LICENSE). Provided as-is, with no warranty. It's my own experiment, so expect it to change, break, or be torn down.
