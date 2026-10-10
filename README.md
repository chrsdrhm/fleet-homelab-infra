[![LinkedIn](https://img.shields.io/badge/LinkedIn-Connect-blue?logo=linkedin)](https://www.linkedin.com/in/chrsdrhm/)

# fleet-homelab-infra

Terraform for a **Fleet Premium** deployment on AWS, built as a homelab project for learning and experimentation.

> **This is a personal learning project, not production guidance.** It runs in my own AWS account, is torn down when I'm not using it, and is here so I can work through the tooling in the open. Take ideas from it, but don't treat it as a hardened reference architecture.

## What this is

[Fleet](https://fleetdm.com) is an open-source device management and osquery platform. I'm standing up a real, publicly reachable Fleet instance to learn how the pieces fit together:

- **Infrastructure:** Fleet's own [`fleet-terraform`](https://github.com/fleetdm/fleet-terraform) root module (VPC, Aurora MySQL, Redis, ALB, ECS Fargate), pinned to a release tag rather than reimplemented.
- **DNS and TLS:** a Route 53 hosted zone for a subdomain, delegated from Cloudflare (also managed in Terraform), with an ACM certificate.
- **Identity:** Okta SAML SSO with just-in-time provisioning and group-based roles, plus a break-glass admin.
- **GitOps:** Fleet's configuration managed from a separate repo with `fleetctl gitops`.
- **CI:** Terraform run from GitHub Actions using OIDC, so there are no long-lived AWS keys in GitHub.
- **Observability:** a Grafana dashboard on my Proxmox server showing infrastructure health and Fleet asset data.

## Cost approach

An always-on stack costs roughly $170/month, which is too much for a homelab. So the design is built to be **fully torn down and rebuilt** (evenings and weekends only), with state that must survive (the Fleet server key, the software-installers bucket, an Aurora snapshot) kept outside the teardown. That averages out to around $12-15/month.

## Status

Work in progress, built task by task from a written plan. Running and verified so far: the core Fleet stack, a US-only WAF, outbound mail through SES, Windows MDM, Okta SAML single sign-on with just-in-time provisioning and group-based roles, and email MFA on the break-glass admin. The Fleet configuration is managed from a separate GitOps repo. Still to come: scripts for the teardown and rebuild routine, CI for this repo, osquery logs to S3, a Grafana dashboard, and device enrollment extras.

## Repo layout

| Path | What it is |
|---|---|
| `*.tf` | The Terraform configuration |
| `docs/specs/` | Design spec: decisions and reasoning |
| `docs/plans/` | The implementation plan, including problems found and fixed while running it |
| `example.tfvars` | Placeholder values; real values live in a gitignored `terraform.tfvars` |

## Security notes

Already true:

- No secrets are committed. Real values live in a gitignored `terraform.tfvars`; Terraform state is in a private, versioned S3 bucket.

Part of the design, being built as the plan progresses:

- CI access to AWS uses short-lived OIDC credentials scoped to this repository and branch, with no long-lived keys in GitHub.
- Repo controls: pull requests from forks get no secrets, workflow runs from outside contributors need my approval, and only I can merge.
- Secret scanning with push protection, and private vulnerability reporting: if you spot something that looks like a security problem, please use this repo's **Security** tab to report it privately instead of opening a public issue.

## Built with AI assistance

I planned and built this with [Claude Code](https://claude.com/claude-code). The design decisions, the account it runs in, and the review of what gets applied are mine; much of the plan text, and a lot of the fact-checking against upstream module source, were done with the assistant. The plan records where an early draft was wrong and got corrected, so those mistakes stay visible instead of being edited out.

## License

[MIT](LICENSE). Provided as-is, with no warranty. It's my own experiment, so expect it to change, break, or be torn down.
