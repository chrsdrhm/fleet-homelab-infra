[![LinkedIn](https://img.shields.io/badge/LinkedIn-Connect-blue?logo=linkedin)](https://www.linkedin.com/in/chrsdrhm/)

# fleet-homelab-infra

Terraform for a **Fleet Premium** deployment on AWS, built as a homelab project for learning and experimentation.

> **This is a personal learning project, not production guidance.** It runs in my own AWS account, is torn down when I'm not using it, and is here so I can work through the tooling in the open. Take ideas from it, but don't treat it as a hardened reference architecture.

## What this is

[Fleet](https://fleetdm.com) is an open-source device management and osquery platform. I'm standing up a real, publicly reachable Fleet instance to learn how the pieces fit together:

- **Infrastructure:** Fleet's own [`fleet-terraform`](https://github.com/fleetdm/fleet-terraform) root module (VPC, Aurora MySQL, Redis, ALB, ECS Fargate), pinned to a release tag rather than reimplemented.
- **DNS and TLS:** a Route 53 hosted zone for a subdomain, delegated from Cloudflare (also managed in Terraform), with an ACM certificate.
- **Identity:** Okta SAML SSO with just-in-time provisioning and group-based roles, plus a break-glass admin. Nobody gets a Fleet role unless they are in one of the two Okta groups.
- **GitOps:** Fleet's configuration managed from a separate repo with `fleetctl gitops`.
- **CI:** Terraform run from GitHub Actions using OIDC, so there are no long-lived AWS keys in GitHub.
- **Observability (planned, optional):** an Amazon Managed Grafana dashboard with alerts, showing infrastructure health and Fleet asset data. It's a separate Terraform root, so you can leave it out; it stays up all the time for about $9 a month.

## Cost

Left running, the stack would cost about **$6.45 a day, or about $196 a month** (roughly $0.27 an hour): mostly Aurora, the NAT Gateway, Fargate, Redis, the load balancer and its public IPv4 addresses. That's too much for a homelab, so it's built to be **torn down when I'm not using it and rebuilt when I am**. Torn down, it costs about **$1.40 a month**. At roughly a weekend a month of use (about 50 hours), that averages out to around **$15 a month**. A $100 AWS Budget emails me at every $10 of spend, mainly to catch a stack I forgot to tear down. The [design spec](docs/specs/fleet-homelab-aws-design.md#cost) has the per-item breakdown.

## Teardown and rebuild

Two scripts do it, and the same scripts run from my laptop or from GitHub Actions:

- **`scripts/down.sh`** (about 18–20 minutes) snapshots the Aurora database, destroys the expensive part of the stack (VPC and NAT Gateway, Aurora, Redis, load balancer, ECS, WAF), keeps the two newest snapshots, and checks that nothing billable is left.
- **`scripts/up.sh`** (about 22 minutes) finds the newest snapshot, rebuilds the stack from it, waits until Fleet answers, and then starts a run in the GitOps repo so Fleet's configuration is reapplied.

What has to survive a teardown is kept outside it: the database (through the snapshot), the Fleet server key that encrypts data in that database, the Windows MDM certificate, the software-installers bucket, DNS and the TLS certificate. A rebuilt Fleet comes back with the same users, hosts, settings and SSO.

## Identity: an Okta free tenant

Single sign-on uses an **Okta Workforce Identity free trial**, which turns into Okta's **Free Plan** after 30 days (up to 10 users, SSO and MFA, no support, $0). Okta can close an org after 45 days of inactivity, so I sign in at least once a month. The Okta side (the Fleet SAML app, two groups that map to Fleet roles, and the role attribute) is Terraform in [`okta/`](okta/), applied from my laptop with an Okta API service app that signs in with a private key. Who is in each group is set by hand in Okta, never by Terraform.

## Status

Work in progress, built task by task from a written plan. Running and verified: the core Fleet stack, a US-only WAF, outbound mail through SES, Windows MDM, Okta SAML single sign-on with just-in-time provisioning and group-based roles, email MFA on the break-glass admin, the teardown and rebuild scripts, and CI for this repo (lint and a plan on every pull request; rebuild and teardown on demand). Fleet's configuration is managed from a separate GitOps repo. Still to come: osquery logs to S3, a Grafana dashboard, end-user SSO at device enrollment, and Apple MDM.

## Repo layout

| Path | What it is |
|---|---|
| `*.tf` | The AWS and Cloudflare Terraform configuration |
| `okta/` | The Okta side: SAML app, groups and role attribute (its own Terraform root, applied locally) |
| `scripts/` | `up.sh`, `down.sh` and `tf-apply.sh` (apply with one known retry) |
| `.github/` | The CI workflow (lint, plan, apply), its shared setup action, Dependabot and CODEOWNERS |
| `docs/specs/` | Design spec: decisions, cost and how teardown works |
| `docs/plans/` | The implementation plan, including problems found and fixed while running it |
| `example.tfvars`, `backend.example.hcl` | Placeholder values; real values live in gitignored `terraform.tfvars` and `backend.hcl` |

## Security notes

- No secrets are committed. Real values live in gitignored files or GitHub secrets; Terraform state is in a private, versioned S3 bucket.
- CI reaches AWS with short-lived OIDC credentials, with no long-lived AWS keys in GitHub. Rebuild and teardown use a role that only manual runs on `main` can assume; pull-request plans use a separate read-only role.
- `main` accepts changes only through pull requests whose lint and plan checks pass, with no bypass, including for me. Plans posted on pull requests are masked, since comments on a public repo are public.
- Pull requests from forks get no secrets, workflow runs from outside contributors need my approval, actions are pinned to commit SHAs, and Dependabot keeps them and the providers current.
- Secret scanning with push protection, and private vulnerability reporting: if you spot something that looks like a security problem, please use this repo's **Security** tab to report it privately instead of opening a public issue.

## Built with AI assistance

I planned and built this with [Claude Code](https://claude.com/claude-code). The design decisions, the account it runs in, and the review of what gets applied are mine; much of the plan text, and a lot of the fact-checking against upstream module source, were done with the assistant. The plan records where an early draft was wrong and got corrected, so those mistakes stay visible instead of being edited out.

## License

[MIT](LICENSE). Provided as-is, with no warranty. It's my own experiment, so expect it to change, break, or be torn down.
