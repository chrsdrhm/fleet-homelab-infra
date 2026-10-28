# Setup guide

How to build this in your own accounts. Steps 1–5 get Fleet running; the rest is optional. Commands are for bash or zsh (Linux, macOS, or WSL on Windows).

The first build takes about 30 minutes. While it's up, the stack costs about $0.25 an hour, so tear it down when you're done (step 9).

## 1. What you need

- **Accounts:**
  - an AWS account (admin access)
  - a domain you control. If its DNS is on Cloudflare, Terraform delegates the Fleet subdomain for you; with any other DNS provider, you add four NS records by hand (step 5).
  - a [Fleet Premium](https://fleetdm.com/pricing) license key
  - GitHub
- **Tools:**
  - [Terraform](https://developer.hashicorp.com/terraform/install) 1.12 or newer (CI uses 1.14.8)
  - [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
  - [GitHub CLI](https://cli.github.com/)
  - git, curl, jq, python3

## 2. Get the code

Fork both repos, keeping their names, and clone them:

```bash
gh repo fork chrsdrhm/fleet-homelab-infra --clone
gh repo fork chrsdrhm/fleet-homelab-gitops --clone
cd fleet-homelab-infra
git config core.hooksPath checks/hooks   # optional: blocks commits that contain private values
```

In both repos, change `.github/CODEOWNERS` to your GitHub username.

## 3. Sign in to AWS and create the state bucket

```bash
aws configure sso && aws sso login        # or any other way the AWS CLI can sign in
export AWS_REGION=us-east-1

BUCKET=fleet-homelab-tfstate-$(aws sts get-caller-identity --query Account --output text)
aws s3api create-bucket --bucket "$BUCKET"
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
printf 'bucket = "%s"\n' "$BUCKET" | tee backend.hcl > okta/backend.hcl
```

The bucket holds Terraform's state. It's created once and never torn down.

## 4. Fill in your settings

```bash
cp example.tfvars terraform.tfvars
```

Then edit `terraform.tfvars`. It's gitignored; never commit it.

| Setting | Value |
|---|---|
| `fleet_subdomain` | Fleet's hostname, e.g. `fleet.example.com` |
| `fleet_license_key` | Your Fleet Premium key |
| `cloudflare_zone_name` | Your domain, e.g. `example.com`. Leave empty if your DNS isn't on Cloudflare. |
| `cloudflare_api_token` | A Cloudflare token made from the **Edit zone DNS** template, for that zone only. Leave empty if your DNS isn't on Cloudflare. |
| `budget_alert_email` | Where cost alerts go |
| `waf_ci_header_value` | A random string: `python3 -c "import secrets; print(secrets.token_hex(32))"` |
| `github_owner`, `github_owner_id`, `github_repo_id` | The output of the command below |

```bash
gh api repos/$(gh api user --jq .login)/fleet-homelab-infra --jq '{github_owner: .owner.login, github_owner_id: .owner.id, github_repo_id: .id}'
```

## 5. Build it

```bash
terraform init -backend-config=backend.hcl
terraform apply -var-file=terraform.tfvars -target=aws_secretsmanager_secret_version.fleet_server_private_key   # first time only
NO_GITOPS=1 ./scripts/up.sh
```

**DNS not on Cloudflare?** Before running `up.sh`, create the Fleet subdomain's DNS zone and delegate it by hand, because the TLS certificate can't be issued until the subdomain points to it:

```bash
terraform apply -var-file=terraform.tfvars -target=aws_route53_zone.fleet
terraform output fleet_name_servers
```

At your DNS provider, add four NS records for `<fleet_subdomain>`, one per name server. Then run `up.sh`. You only do this once, because the zone survives teardowns.

When it finishes, open `https://<fleet_subdomain>/` and create the first admin account. Keep its password in your password manager.

**Email:** Fleet sends invites and MFA codes through Amazon SES, which in a new AWS account only delivers to verified addresses. To get them, verify your own address once:

```bash
aws sesv2 create-email-identity --email-identity you@example.com
```

Then click the link in the email AWS sends.

## 6. Optional: Okta single sign-on

1. Create an [Okta free trial](https://www.okta.com/free-trial/) org. It becomes a free plan after 30 days; sign in monthly to keep it active.
2. Create an **API Services** app for Terraform: Applications → Create App Integration → Classic experience.
   - Use a key pair, and save the private key outside the repo.
   - Grant it `okta.apps.manage` and `okta.groups.manage`, and the Super Administrator role.
3. Apply the Okta side:
   ```bash
   cd okta && cp example.tfvars terraform.tfvars   # fill it in
   terraform init -backend-config=backend.hcl && terraform apply -var-file=terraform.tfvars
   ```
4. Add yourself to the **Fleet Admins** group in the Okta console. To sign in while enrolling a device, also add yourself (or whoever owns the device) to **Fleet Device Users**.

Fleet picks up the Okta settings from the GitOps repo (step 7).

## 7. The GitOps repo (Fleet's configuration)

1. **Create an API user for GitOps:**
   - In Fleet, go to My account → Get API token.
   - In a separate terminal, run:
     ```bash
     fleetctl config set --address https://<fleet_subdomain> --token <your token>
     fleetctl user create --name "GitOps CI" --global-role gitops --api-only
     ```
   - The second command prints the new user's token once; copy it for the next step.
2. **Set its secrets and settings** (Fleet's URL, the token from step 1, the WAF header, and the Okta values if you use Okta): see [GitHub setup](github-setup.md). Without Okta, also set `enable_sso: false` in its `default.yml`, remove its `end_user_authentication` block, and remove `enable_end_user_authentication` from `fleets/workstations.yml`.
3. **Run it:**
   ```bash
   gh workflow run workflow.yml --repo <you>/fleet-homelab-gitops
   ```

From then on, `up.sh` starts this run after every rebuild.

**GitOps mode is on** (in its `default.yml`): Fleet's UI shows everything the repo manages as read-only, so changes go through pull requests. Keep it on: the repo defines everything, so anything made in the UI would be deleted by the next GitOps run, with no warning. Fleet can leave labels, software or enroll secrets editable in the UI; the [GitOps README](https://github.com/chrsdrhm/fleet-homelab-gitops#gitops-mode-the-ui-is-read-only) explains when you'd want that.

## 8. Optional: CI for the infrastructure

This is CI for the Terraform in this repo, plus checks and reviews on both repos' pull requests. It's separate from the GitOps workflow in step 7, which applies Fleet's configuration and isn't optional. CI is optional, but worth it. **To set it up, follow [GitHub setup](github-setup.md)**, which covers both repos step by step.

With it, every pull request is checked before it can merge, and the results land on the pull request itself:
- **Lint and tests:** a ❌ comment names any check that fails, including one that catches a private value about to go public.
- **Terraform plan:** exactly what will change in AWS, with secrets masked, and a failed check if the change would destroy data.
- **Claude review (optional):** a ✅ / ⚠️ / ❌ verdict against Fleet's approach and AWS and endpoint security baselines; comment `@claude` to review again after a fix.
- **Changes go live on merge** while the stack is up (while it's down, the next `up` applies them), and **`up` and `down` run from GitHub**, without your terminal.

See it on closed example pull requests: in infra, [a change with its plan and review](https://github.com/chrsdrhm/fleet-homelab-infra/pull/47) (including an `@claude` re-review after a fix) and [a lint failure](https://github.com/chrsdrhm/fleet-homelab-infra/pull/44); in GitOps, [a new policy with its review](https://github.com/chrsdrhm/fleet-homelab-gitops/pull/27) and [a lint failure on a private value](https://github.com/chrsdrhm/fleet-homelab-gitops/pull/30).

To have CI check for your own private values (your hostname, account ID and so on, stored only as hashes), run:

```bash
python3 checks/private-values/check.py --from-tfvars && checks/private-values/sync-hashes.sh
```

[`checks/README.md`](../checks/README.md) covers all the checks.

## 9. Day to day

| To | Run |
|---|---|
| Tear down (keeps your data) | `./scripts/down.sh`. With CI, a nightly check also does it overnight if the stack is still up (see below to change or skip it). |
| Bring it back | `./scripts/up.sh` |
| Run the checks locally | `checks/install-tools.sh`, then `checks/run.sh` |
| Upgrade Fleet | Follow [Upgrading Fleet](upgrading-fleet.md), or run `/fleet-upgrade` in Claude Code |

With [Claude Code](https://claude.com/claude-code), `/session-start` and `/session-end` (in `.claude/skills/`) do the routine around these: check sign-ins, open pull requests and runs in progress, run `up` or `down`, check the result, and handle the nightly teardown and leftover snapshots. They ask before setting the teardown variable or deleting anything, and `/session-end` asks before tearing down.

**Changing the nightly teardown.** It's the `schedule` in `.github/workflows/terraform.yml`:
- **Another time:** cron is in UTC and ignores daylight saving, so 07:17 UTC is 2:17am in Chicago in summer and 1:17am in winter. GitHub often starts scheduled runs late, sometimes by hours, so the "Decide what to run" step tears down only if the run starts between midnight and 7:59am in `America/Chicago`; later than that, it leaves the stack up and opens an issue, "The nightly teardown didn't run", which closes once a teardown succeeds or a later check finds the stack down. Change the cron time, and the time zone and hours in that step.
- **Off for a night:** set the `AUTO_DOWN_SKIP_UNTIL` repository variable ([GitHub setup](github-setup.md)).
- **Off for good:** delete the `schedule` block.

**Notices in issues.** If a teardown fails (the nightly one or one you started), the run opens an issue in this repo, "The teardown failed", because the stack may still be partly up and billing; GitHub sends it to you by email and in its app, and the next successful teardown closes it. The nightly run also lists Aurora snapshots that aren't teardown snapshots and are older than 14 days (a pre-upgrade snapshot, say) in a "Kept snapshots older than 14 days" issue, since they bill until deleted; it updates nightly and closes itself once there are none. And when Fleet has a release that's been out for a week and is newer than `fleet.Dockerfile`, an "A newer Fleet release is available" issue links its notes, until an upgrade catches up ([Upgrading Fleet](upgrading-fleet.md)); optionally, Claude adds a first review of the releases to it ([GitHub setup step 7](github-setup.md#7-optional-claude-reviews-new-fleet-releases)). None of them changes anything.

If something goes wrong, the [plan](plans/fleet-homelab-aws-deployment.md) records every problem hit while building this and its fix. Search it for the error message.
