[![LinkedIn](https://img.shields.io/badge/LinkedIn-Connect-blue?logo=linkedin)](https://www.linkedin.com/in/chrsdrhm/)

# fleet-homelab-infra

Terraform for a **Fleet Premium** deployment on AWS, built as a homelab project for learning and experimentation.

> **This is a personal learning project, not production guidance.** It runs in my own AWS account, is torn down when I'm not using it, and is here so I can work through the tooling in the open. Fleet's own configuration (SSO, fleets, policies) lives in a separate repo: [`fleet-homelab-gitops`](https://github.com/chrsdrhm/fleet-homelab-gitops). Take ideas from this repo, but don't treat it as a hardened reference architecture.

## What this is

[Fleet](https://fleetdm.com) is an open-source device management and osquery platform. I'm standing up a real, publicly reachable Fleet instance to learn how the pieces fit together:

- **Infrastructure:** Fleet's own [`fleet-terraform`](https://github.com/fleetdm/fleet-terraform) root module (VPC, Aurora MySQL, Redis, ALB, ECS Fargate), pinned to a release tag rather than reimplemented.
- **DNS and TLS:** a Route 53 hosted zone for a subdomain, with an ACM certificate. **Cloudflare is optional:** if the domain's DNS is on Cloudflare (as mine is), Terraform delegates the subdomain too; with any other DNS provider, you add four NS records by hand once.
- **Identity (optional):** Okta SAML SSO with just-in-time provisioning and group-based roles, plus a break-glass admin. Nobody gets a Fleet role unless they are in one of the two Okta groups. It's a separate Terraform root, so you can leave it out and use password logins instead (see below).
- **GitOps:** Fleet's configuration managed from a separate repo with `fleetctl gitops`.
- **CI:** Terraform run from GitHub Actions using OIDC, so there are no long-lived AWS keys in GitHub. Every pull request is linted, tested against mocked providers, and planned, and merging it applies the change while the stack is up; the checks live in [`checks/`](checks/README.md). Optionally, an AI reviews each pull request too: Claude with a Claude subscription, or GitHub Copilot or another tool instead. With Claude, comment `@claude` on a pull request to review its latest commit again (see [GitHub setup](docs/github-setup.md#6-optional-claude-reviews-pull-requests)).
- **Checks on the running stack (optional):** after every rebuild, and after every change that goes live (a Fleet upgrade, say), CI runs a read-only health scan and has Claude compare it with what's normal, and when Fleet ships a new release, Claude reviews it against this setup before I upgrade. Either opens an issue when something needs a look. Both use the Claude API, signing in from GitHub Actions with workload identity federation, so there's no API key to store.

## Getting started

To build this in your own AWS account, follow the [setup guide](docs/setup.md): five steps to a running Fleet, then optional Okta single sign-on, the GitOps repo, and CI.

## Cost

Left running, the stack would cost about **$7 a day, or about $200 a month** (roughly $0.25 an hour): mostly Aurora, the NAT Gateway, Fargate, Redis, the load balancer, and the public IPv4 addresses of the load balancer and NAT Gateway. That's too much for a homelab, so it's built to be **torn down when I'm not using it and rebuilt when I am**, without starting over: the database, users, hosts and settings come back each time (see [Teardown and rebuild](#teardown-and-rebuild)). Torn down, it costs about **$2 a month**, plus well under $1 a month of Claude API use for the optional checks. At roughly a weekend a month of use (about 50 hours), that averages out to around **$15 a month**. Two things catch a stack I forget to tear down: a nightly check brings it down if it's still up overnight, so forgetting costs at most about a day (around $7), and a $100 AWS Budget emails me at every $10 of spend. The [design spec](docs/specs/fleet-homelab-aws-design.md#cost) has the per-item breakdown.

## Teardown and rebuild

**A rebuilt Fleet picks up where you left off: the same users, hosts, settings and SSO.** Nothing starts fresh. Two scripts do it, and the same scripts run from my terminal or from GitHub Actions:

- **`scripts/down.sh`** (about 20 minutes) snapshots the Aurora database, destroys the expensive part of the stack (VPC and NAT Gateway, Aurora, Redis, load balancer, ECS, WAF), keeps the two newest snapshots, and checks that nothing billable from the stack is left.
- **`scripts/up.sh`** (about 20 minutes) finds the newest snapshot, rebuilds the stack from it, waits until Fleet answers, and then starts a run in the GitOps repo so the latest Fleet configuration is reapplied, including any changes merged there while the stack was down, and a health scan.
- **From GitHub:** with CI, either one runs on GitHub's machines, started from the Actions tab (on github.com or in the GitHub mobile app) or `gh workflow run`, so nothing has to stay open: start a `down` and walk away ([setup guide](docs/setup.md#9-day-to-day)).
- **A nightly check** in GitHub Actions tears the stack down if it's still up overnight (it's scheduled for 2:17am Chicago time, 1:17am in winter, and acts whenever GitHub starts it before 8am), so a forgotten stack costs a few hours, not a month. If a teardown fails, or GitHub starts the check too late to act, an issue says so. To keep it up, set the `AUTO_DOWN_SKIP_UNTIL` repository variable to the last day you want it up; the check the next night brings it down as usual (see [GitHub setup](docs/github-setup.md)).

The teardown only removes the expensive parts; everything that holds state stays. The database is snapshotted before it's deleted and restored on the way back up, and Apple MDM's push certificate and keys are stored in it. The Fleet server key that encrypts it, the Windows MDM certificate (in Secrets Manager), the software-installers bucket, DNS, the TLS certificate and the email sending identity are never torn down.

## Sized for a homelab

Fleet's Terraform module is used as published (pinned to a release tag), with smaller inputs. Its defaults and Fleet's own [reference architectures](https://fleetdm.com/docs/deploy/reference-architectures) are built for thousands of hosts, with database replicas, three Redis nodes and several Fleet servers. This homelab has about ten hosts, so it runs one Fleet server (autoscaling to two at most), one Aurora instance of the size Fleet recommends for up to 5,000 hosts, and one Redis node. That's plenty of performance at this scale; what it gives up is failover, which a homelab doesn't need, since the recovery plan is a rebuild from the snapshot. It's also most of why the stack costs about $200 a month left running instead of several times that. The [design spec](docs/specs/fleet-homelab-aws-design.md#sizing-compared-with-fleets-defaults-and-guidance) has the side-by-side comparison.

## Identity: an Okta free tenant

Single sign-on uses an **Okta Workforce Identity free trial**, which turns into Okta's **Free Plan** after 30 days (up to 10 users, SSO and MFA, no support, $0). Okta can close an org after 45 days of inactivity, so I sign in at least once a month. The Okta side (the Fleet SAML app, two groups that map to Fleet roles, the role attribute, and a second app that device owners sign in to while enrolling) is Terraform in [`okta/`](okta/), applied from my terminal with an Okta API service app that signs in with a private key. Who is in each group is set by hand in Okta, never by Terraform.

**Okta is optional.** Fleet runs fine without single sign-on: users then sign in with a password, starting with the admin you create on first setup. I use Okta because it makes the lab more like a real deployment, where people sign in through the company's identity provider and get their Fleet role from it. To leave it out, don't apply `okta/`, and turn SSO off in the GitOps repo's `default.yml` (see [setup step 7](docs/setup.md#7-the-gitops-repo-fleets-configuration)). Fleet's SSO is standard SAML, so any other SAML identity provider works too; you'd configure that one by hand or in its own Terraform. The small public bucket for the login button's logo (`idp_logo.tf`) is only for SSO, and you can delete it.

## Repo layout

| Path | What it is |
|---|---|
| `*.tf` | The Terraform configuration: AWS, plus the optional Cloudflare delegation (`cloudflare.tf`) |
| `fleet.Dockerfile` | The Fleet server version, in one `FROM` line. It's never built; `fleet.tf` reads it |
| `okta/` | Optional. The Okta side: the admin and enrollment SAML apps, groups and role attribute (its own Terraform root, applied locally) |
| `scripts/` | `up.sh`, `down.sh` and `tf-apply.sh` (apply with one known retry); `health-scan.sh` (read-only health scan) and `health-review.sh` (Claude compares it with the baseline); `release-review.sh` (Claude reviews new Fleet releases); `claude-message.sh` (the Claude API call both use) and `notify-issue.sh` (the issues CI opens) |
| `.claude/skills/` | Claude Code skills: `/session-start`, `/session-end`, `/fleet-upgrade` and `/health-scan` (with the scan's baseline) |
| `checks/` | Every lint check, test and guard, with its own [README](checks/README.md): run them locally with `checks/run.sh`, or delete the folder to drop them all |
| `.github/` | The CI workflows: `terraform.yml` (lint, plan, apply, up and down, the nightly teardown), `fleet-checks.yml` (the release check and the health scan) and `claude-review.yml` (the optional Claude review); the shared setup action, Dependabot and CODEOWNERS |
| `AGENTS.md`, `CLAUDE.md` | Rules for AI assistants working in or reviewing this repo. `AGENTS.md` holds them and is read by Claude Code, GitHub Copilot and other tools; `CLAUDE.md` only imports it, for Claude Code setups that read nothing else. |
| `docs/` | The [setup guide](docs/setup.md), [GitHub setup](docs/github-setup.md) and [Upgrading Fleet](docs/upgrading-fleet.md) |
| `docs/specs/` | Design spec: decisions, cost and how teardown works |
| `docs/plans/` | The implementation plan, including problems found and fixed while running it |
| `example.tfvars`, `backend.example.hcl` | Placeholder values; real values live in gitignored `terraform.tfvars` and `backend.hcl` |

## Security notes

- **No AWS keys in GitHub.** CI reaches AWS through OIDC. Rebuild and teardown use a role that only manual runs on `main` can assume; pull-request plans use a separate read-only role, and the health scan a third, which can only read what the scan checks. Claude's checks sign in the same way, with no API key: GitHub's identity token is exchanged for a Claude API token that lasts minutes.
- **No shortcuts to `main`.** Every change goes through a pull request whose lint and plan checks pass, with no bypass, including for me. Plans posted on pull requests are masked, since comments on a public repo are public. A plan that would destroy or replace something holding data (the database, a secret, a bucket, DNS, the certificate) fails its check unless the pull request has the `allow-destroy` label.
- **No private values in the repo.** Every pull request is checked for AWS account IDs, Okta org and app IDs, personal email addresses and signed tokens, by pattern. Values a pattern can't describe (like my hostname) are checked against a list of their SHA-256 hashes in a repository secret, so the list contains no plaintext. It reports where it found something, never the value. Values that look real in examples and tests (`123456789012`, `example.com`) are standard placeholders. **If you reuse this repo:** the patterns work with no setup, and [`checks/README.md`](checks/README.md) explains adding your own values, the optional local hooks, and how to remove the checks entirely.
- **Found a problem?** Please [report it privately](https://github.com/chrsdrhm/fleet-homelab-infra/security/advisories/new) through this repo's **Security** tab instead of opening a public issue.

## Built with AI assistance

I planned and built this with [Claude Code](https://claude.com/claude-code). The design decisions, the account it runs in, and the review of what gets applied are mine; much of the plan text, and a lot of the fact-checking against upstream module source, were done with the assistant. Rules for AI assistants working in or reviewing this repo are in [`AGENTS.md`](AGENTS.md), which Claude Code, GitHub Copilot and other tools read; `CLAUDE.md` only imports it, for Claude Code setups that read nothing else.

## License

[MIT](LICENSE). Provided as-is, with no warranty. It's my own experiment, so expect it to change, break, or be torn down.
