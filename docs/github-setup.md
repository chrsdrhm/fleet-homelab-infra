# GitHub setup

The GitHub side of both repos: secrets and variables, repository settings, branch rules, a label, an optional GitHub App, and the optional Claude reviews and checks (steps 6–8). It's part of the [setup guide](setup.md) (steps 7 and 8). Run the commands from anywhere the GitHub CLI is signed in. Set `OWNER` first:

```bash
OWNER=$(gh api user --jq .login)
```

Do the steps in this order. The branch rules require checks that must have run at least once; a required check that has never run blocks every merge.

## 1. Secrets and variables

`gh secret set NAME --repo $OWNER/<repo>` prompts for the value, so it stays out of your shell history. Add `--app dependabot` to set the Dependabot copy: Dependabot's pull requests can only read Dependabot secrets.

**`fleet-homelab-infra`:**

| Secret | Value | Also for Dependabot |
|---|---|---|
| `AWS_ROLE_ARN` | `terraform output -raw github_actions_apply_role_arn` | |
| `AWS_PLAN_ROLE_ARN` | `terraform output -raw github_actions_plan_role_arn` | yes |
| `AWS_SCAN_ROLE_ARN` | Optional, for the health scan after `up` (step 8): `terraform output -raw github_actions_scan_role_arn` | |
| `TF_STATE_BUCKET` | Your state bucket's name | yes |
| `FLEET_SUBDOMAIN`, `FLEET_LICENSE_KEY`, `BUDGET_ALERT_EMAIL`, `WAF_CI_HEADER_VALUE` | The same values as in `terraform.tfvars` | yes |
| `CLOUDFLARE_ZONE_NAME`, `CLOUDFLARE_API_TOKEN` | The same as in `terraform.tfvars`; skip both if your DNS isn't on Cloudflare | yes |
| `GITOPS_APP_CLIENT_ID`, `GITOPS_APP_PRIVATE_KEY` | Optional, from the GitHub App in step 5 | |
| `PRIVATE_HASHES` | Set by `checks/private-values/sync-hashes.sh` (see [`checks/README.md`](../checks/README.md#private-values)) | yes (the script sets both) |
| `CLAUDE_CODE_OAUTH_TOKEN` | Optional, for Claude reviews (step 6) | |
| `ANTHROPIC_ORGANIZATION_ID`, `ANTHROPIC_FEDERATION_RULE_ID`, `ANTHROPIC_SERVICE_ACCOUNT_ID` | Optional, for Claude's review of new Fleet releases (step 7) and of the health scan (step 8); IDs, not credentials | |
| `ANTHROPIC_WORKSPACE_ID` | Optional, only if the federation rule in step 7 covers more than one workspace | |
| `OKTA_ORG_NAME`, `OKTA_PLAN_CLIENT_ID`, `OKTA_PLAN_PRIVATE_KEY_ID`, `OKTA_PLAN_PRIVATE_KEY` | Optional, for the Okta plan on pull requests (step 9): your `okta_org_name`, and the read-only service app's client ID, key ID and private key | |

**`fleet-homelab-gitops`:**

| Secret | Value |
|---|---|
| `FLEET_URL` | `https://<fleet_subdomain>` |
| `FLEET_API_TOKEN` | The GitOps API user's token ([setup guide step 7](setup.md#7-the-gitops-repo-fleets-configuration)) |
| `FLEET_CI_HEADER` | Your `waf_ci_header_value` |
| `FLEET_OKTA_METADATA_URL`, `FLEET_IDP_IMAGE_URL` | Only with Okta: `terraform output -raw metadata_url` (in `okta/`) and `terraform output -raw idp_logo_url` |
| `FLEET_END_USER_OKTA_METADATA_URL` | Only with Okta, for the sign-in at enrollment: `terraform output -raw enduser_metadata_url` (in `okta/`) |
| `PRIVATE_HASHES` | Set by `sync-hashes.sh`, which also sets the Dependabot copy |
| `CLAUDE_CODE_OAUTH_TOKEN` | Optional, for Claude reviews (step 6) |

**Optional repository variables.** These aren't secret (anyone who can see the repo's settings can read them), so they're variables: `gh variable set NAME --body VALUE --repo $OWNER/<repo>`.

| Variable | Repo | What it does |
|---|---|---|
| `AUTO_DOWN_SKIP_UNTIL` | `fleet-homelab-infra` | The last day the stack stays up; the nightly teardown skips until then (see **Nightly teardown** below). |
| `CLAUDE_REVIEW_MODEL` | either | Pins the Claude reviews' model; without it, your plan's default for pull requests (step 6) and `claude-opus-5-5` for new releases and the health scan (steps 7 and 8). |

## 2. Repository settings

These run the same in both repos; only the list of allowed actions differs:
- **Infra:** the AWS and Terraform setup actions.
- **GitOps:** GitHub's own actions only.
- **Both:** the Claude review action and the action it uses internally, only if you use the optional review in step 6.

```bash
for repo in fleet-homelab-infra fleet-homelab-gitops; do
  R=repos/$OWNER/$repo
  # Pull requests from outside contributors wait for your approval before their workflows run
  gh api -X PUT $R/actions/permissions/fork-pr-contributor-approval -f approval_policy=all_external_contributors
  # Workflows get a read-only token and can't approve pull requests
  gh api -X PUT $R/actions/permissions/workflow -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false
  # Only allowed actions run, each pinned to a full commit SHA
  gh api -X PUT $R/actions/permissions -F enabled=true -f allowed_actions=selected -F sha_pinning_required=true
  # Secret scanning with push protection; Dependabot alerts and security updates; private vulnerability reports
  gh api -X PATCH $R -F 'security_and_analysis[secret_scanning][status]=enabled' \
    -F 'security_and_analysis[secret_scanning_push_protection][status]=enabled'
  gh api -X PUT $R/vulnerability-alerts
  gh api -X PUT $R/automated-security-fixes
  gh api -X PUT $R/private-vulnerability-reporting
  # Delete a pull request's branch when it merges; no wiki or projects
  gh api -X PATCH $R -F delete_branch_on_merge=true -F has_wiki=false -F has_projects=false
done

# Allowed actions besides GitHub's own (sent as JSON: the API rejects "@*" entries passed with -f).
# The last two are only for the optional Claude review (step 6).
echo '{"github_owned_allowed":true,"verified_allowed":false,"patterns_allowed":["aws-actions/*","hashicorp/*","anthropics/claude-code-action@*","oven-sh/setup-bun@*"]}' \
  | gh api -X PUT repos/$OWNER/fleet-homelab-infra/actions/permissions/selected-actions --input -
echo '{"github_owned_allowed":true,"verified_allowed":false,"patterns_allowed":["anthropics/claude-code-action@*","oven-sh/setup-bun@*"]}' \
  | gh api -X PUT repos/$OWNER/fleet-homelab-gitops/actions/permissions/selected-actions --input -

# The label that accepts a plan which destroys or replaces data (infra only)
gh label create allow-destroy --repo $OWNER/fleet-homelab-infra --color B60205 \
  --description "Accept a plan that destroys or replaces a resource that holds data"
```

**Nightly teardown.** With CI set up, the Terraform workflow checks every night (07:17 UTC: 2:17am Chicago time, 1:17am in winter) and runs `down` if the stack is still up, as long as GitHub starts it before 8am in Chicago. To keep the stack up, set `AUTO_DOWN_SKIP_UNTIL` to the last day you want it up; the check the next night brings it down as usual. Delete the variable when you're done:

```bash
gh variable set AUTO_DOWN_SKIP_UNTIL --body 2026-10-14 --repo $OWNER/fleet-homelab-infra   # up through Wednesday the 14th; down early on the 15th
gh variable delete AUTO_DOWN_SKIP_UNTIL --repo $OWNER/fleet-homelab-infra
```

The Terraform workflow also opens issues: one when a teardown fails (closed by the next one that succeeds), one when the nightly check starts too late to tear down a stack that's up, one listing kept snapshots older than 14 days, and one when a newer Fleet release is out (see the setup guide's [Day to day](setup.md#9-day-to-day)). Leave **Issues** turned on in the repo's settings for them.

GitHub turns off scheduled workflows in a public repo after 60 days without activity; it emails you first, and any push turns them back on.

## 3. Run the checks once

Open a small pull request in each repo, such as a one-line README edit, and let its checks run. This registers the check names (`terraform-lint` and `terraform-plan` in infra; `fleet-gitops` and `gitops-lint` in GitOps), which the branch rules in the next step require. Merge or close the pull requests afterwards.

## 4. Branch rules

A ruleset named `protect-main` on the default branch, with no bypass, not even for you:
- Every change goes through a pull request whose required checks pass, on a branch that's up to date with `main` (so what's checked and planned is what gets merged, and in infra, applied)
- `main` can't be deleted or force-pushed

```bash
ruleset() { # repo, then the required check names
  local repo=$1; shift
  local checks; checks=$(printf '{"context":"%s"},' "$@"); checks="[${checks%,}]"
  gh api -X POST repos/$OWNER/$repo/rulesets --input - <<EOF
{ "name": "protect-main", "target": "branch", "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "bypass_actors": [],
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "pull_request", "parameters": { "required_approving_review_count": 0,
      "dismiss_stale_reviews_on_push": true, "require_code_owner_review": false,
      "require_last_push_approval": false, "required_review_thread_resolution": false,
      "require_extra_approval_for_unattributed_changes": true } },
    { "type": "required_status_checks", "parameters": { "strict_required_status_checks_policy": true,
      "required_status_checks": $checks } }
  ] }
EOF
}
ruleset fleet-homelab-infra terraform-lint terraform-plan
ruleset fleet-homelab-gitops fleet-gitops gitops-lint
```

Settings → Rules → Rulesets shows the result. If CI itself ever breaks, an admin can edit the ruleset there temporarily; there's no other way around it.

## 5. Optional: GitHub App for the GitOps run

When `up` runs from CI, it starts the GitOps repo's workflow so Fleet's configuration is reapplied. A workflow's own token can't start another repo's workflow, so a small GitHub App does it. Without the app, `up` still works, but it shows a warning and the nightly GitOps run catches up instead.

1. Go to GitHub → your avatar → **Settings → Developer settings → GitHub Apps → New GitHub App**:
   - Webhook off.
   - Repository permissions → **Actions: Read and write**, and nothing else.
   - **Only on this account**.
2. On the app's page, note the **Client ID** and **generate a private key**. GitHub downloads it as a `.pem` file.
3. **Install App** → your account → **Only select repositories** → `fleet-homelab-gitops`.
4. Store both in the infra repo, then delete the `.pem`:
   ```bash
   gh secret set GITOPS_APP_CLIENT_ID --repo $OWNER/fleet-homelab-infra
   gh secret set GITOPS_APP_PRIVATE_KEY --repo $OWNER/fleet-homelab-infra < path/to/app.private-key.pem
   ```

The key doesn't expire. Each `up` gets a token from it that only works on the GitOps repo, only for Actions, and is revoked when the job ends. If the key ever leaks, generate a new one on the app's page and delete the old one.

## 6. Optional: Claude reviews pull requests

Claude reviews each pull request when it's opened (`.github/workflows/claude-review.yml`, following `AGENTS.md`), with inline comments and one summary carrying a ✅ / ⚠️ / ❌ verdict. **It needs a Claude Pro or Max subscription**; reviews count against your plan, with no separate bill. Without the token the job skips, and it's never a required check.

**Set it up:**
1. Create a token, valid for a year. Run this in a terminal, not through an AI assistant, because it prints the token:
   ```bash
   claude setup-token
   ```
2. Store it in both repos (the command prompts for the value):
   ```bash
   gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo $OWNER/fleet-homelab-infra
   gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo $OWNER/fleet-homelab-gitops
   ```
3. Make sure both actions it needs are in the allow-list (step 2).
4. Set a reminder to renew the token in a year. Once it expires, the review fails until you do (merges aren't blocked).

**Using it:**
- **While a review runs**, its comment shows ⏳ and a link to watch it live. Each new review goes at the bottom of the pull request, and earlier ones are hidden as outdated.
- **To review again** after pushing, comment `@claude`. It reacts 👀, then 🚀 when done (😕 if it failed). Only people with write access can trigger it, since each review uses your plan. Re-running from the Checks tab reviews the old commit instead.
- **Drafts** are skipped until you comment `@claude`. **Dependabot** pull requests don't get the token, but `@claude` reviews them. **Forks** are never reviewed: Claude Code would load the fork's settings, including hooks that run commands, while holding your token.
- **Model:** your plan's default. To pin one, set a repository variable, for example `gh variable set CLAUDE_REVIEW_MODEL --body claude-sonnet-5-5 --repo $OWNER/fleet-homelab-infra`.

**Security:**
- **The Claude token** can only make model requests; it can't open your chats or change your account. GitHub gives it only to runs in your repo, never to forks or Dependabot, and masks it in logs. Any workflow in the repo could read it, so it's as safe as who can change workflows: here, only you, through pull requests. Delete the secret to stop reviews.
- **GitHub access** uses the job's own token, which expires with the run and can only read the repo and comment on pull requests (as `github-actions[bot]`).
- **What Claude can look at:** the repo, plus Fleet's docs, GitHub and the standards sites `AGENTS.md` lists.

**Usage:** expand **📊 Usage summary** on the summary comment. The run's summary page adds a list-price estimate, which isn't billed on a subscription.
- **Input tokens:** everything Claude read, including the diff, files, `AGENTS.md`, fetched pages, and the conversation so far, which is sent again every turn. **Read from cache** is the part already sent: about a tenth of the price, and 80–90% is typical.
- **Output tokens:** what it wrote (a token is about ¾ of a word). **Turns:** how many times it used a tool, such as reading a file. **Duration:** how long it took.
- **A lot or a little?** A small pull request takes about 100,000 input tokens, 1,000–2,000 output, 4–5 turns and under a minute: about $0.10 at API prices. To see the effect on your plan, check **claude.ai → Settings → Usage** (or `/usage` in Claude Code) before and after.

### Using a different reviewer, or none

`AGENTS.md` holds the review instructions, and most AI tools read it as-is, so switching tools doesn't change them.
- **None:** do nothing; without the secret, the job skips. To remove it, delete `.github/workflows/claude-review.yml` and its two allow-list entries (`anthropics/claude-code-action@*` and `oven-sh/setup-bun@*`).
- **GitHub Copilot:** needs Copilot Pro or higher (Copilot Free can't review pull requests), and each review uses Copilot AI credits. Turn on **Automatically request Copilot code review** in Settings → Rules → Rulesets → `protect-main`. Nothing else changes.
- **Another tool:** for a GitHub App, follow its instructions and give it only the repos and permissions it asks for. For a GitHub Action, pin it to a full commit SHA, add it and any action it uses to the allow-list, store its credential as a secret, and limit it to reading the repo and commenting on pull requests.

## 7. Optional: Claude reviews new Fleet releases

When the daily release check opens or updates "A newer Fleet release is available", the same job (`fleet-release` in `fleet-checks.yml`, running `scripts/release-review.sh`) has Claude review the releases in between against this setup, and adds the verdict to the issue ([upgrading Fleet](upgrading-fleet.md#1-read-the-release-notes)). Each upgrade is reviewed once, not daily. **It uses the Claude API, not your subscription**, and signs in with workload identity federation: the job exchanges its GitHub identity token for a Claude API token that lasts about ten minutes, so there's no API key to store or rotate. Without the three secrets the review fails with a warning; the release check and the issue are unaffected.

**Set it up** in the [Claude Console](https://platform.claude.com) (you need the admin or owner role):
1. **A workspace for this repo,** with a monthly spend limit (about $10 is plenty).
2. **Settings → Workload identity → Connect workload → GitHub Actions.** The wizard registers GitHub's issuer and creates a federation rule and a service account. In the rule:
   - **GitHub organization:** your account, plus its numeric ID (`gh api users/$OWNER -q .id`), so the rule survives a rename of the name.
   - **Repository:** `fleet-homelab-infra`. **Branch:** `refs/heads/main`.
   - **Subject:** GitHub may issue this repo's tokens in its immutable format, with numeric IDs (`repo:<owner>@<owner-id>/fleet-homelab-infra@<repo-id>:ref:refs/heads/main`), which the wizard's prefix doesn't match. If a test fails with `match_subject_prefix` in the history, set the rule's subject prefix to the `sub` that entry shows.
   - **Allowed events:** scheduled and manual runs (`schedule` and `workflow_dispatch`). Never pull requests.
   - **Workspaces:** only the new one. Token lifetime: 10 minutes.
   - **Afterwards, add the service account to that workspace** (Settings → Workspaces → the workspace → Members, Developer role). Without it, sign-in fails with `no_workspace`.
3. **Store the three IDs** (`gh secret set` prompts for each value): your organization ID (Settings → Organization), and the rule's (`fdrl_…`) and service account's (`svac_…`):
   ```bash
   gh secret set ANTHROPIC_ORGANIZATION_ID --repo $OWNER/fleet-homelab-infra
   gh secret set ANTHROPIC_FEDERATION_RULE_ID --repo $OWNER/fleet-homelab-infra
   gh secret set ANTHROPIC_SERVICE_ACCOUNT_ID --repo $OWNER/fleet-homelab-infra
   ```
   If the rule covers more than one workspace, also set `ANTHROPIC_WORKSPACE_ID`.
4. **Test it** from the Actions tab: run the `Fleet checks` workflow on `main` with `action` set to `review`, and `review_from` and `review_to` set to two past versions (for example 4.93.0 and 4.93.2). The review appears on the run's summary page, not in an issue. A failed sign-in shows in the Console under Workload identity → history.

**Security:**
- **Only `main` can sign in.** A pull request's run has a different identity, so the rule rejects it, and forks get no identity token at all. Changing what runs on `main` takes a merged pull request.
- **Claude gets no tools.** The release notes are untrusted input, so the job sends everything in one request and posts only Claude's text, with any `@mentions` broken so it can't notify anyone. The job has no AWS access and none of the Terraform secrets.
- **The spend limit caps the cost.** A review sends about 10,000–50,000 tokens: cents to tens of cents, once per release.

## 8. Optional: a health scan after every `up`

After a successful `up` (from CI or from your terminal, where `up.sh` starts it with your GitHub login), and after an apply on merge that changed something (a Fleet upgrade, say), `terraform.yml` starts the health scan in the `Fleet checks` workflow (`fleet-checks.yml`, shown as "Health scan after up" or "Health scan after apply on merge"). Its `health-scan` job runs `scripts/health-scan.sh` over the last two hours, has Claude compare it with [`baseline.md`](../.claude/skills/health-scan/baseline.md) (`scripts/health-review.sh`), and writes both to the run's summary. If something is outside the baseline, it opens "The health scan found something to look at", which the next clean scan closes. It never holds up or fails the `up` or the apply: a scan or comparison that fails only warns. It needs step 7's Claude setup.

**Set it up:**
1. **Create the scan role** locally (CI can't change its own roles): `terraform apply -var-file=terraform.tfvars -target=aws_iam_role_policy_attachment.github_actions_scan`.
2. **Store its ARN** (this prints nothing):
   ```bash
   gh secret set AWS_SCAN_ROLE_ARN --repo $OWNER/fleet-homelab-infra --body "$(aws iam get-role --role-name fleet-homelab-github-actions-scan --query Role.Arn --output text)"
   ```
3. **Test it** from the Actions tab: run the `Fleet checks` workflow on `main` with `action` set to `scan` while the stack is up. By hand, it scans the last day.

**Security:**
- **The scan role only reads.** It allows exactly the calls the scan makes, and Logs Insights queries only on Fleet's log group. It trusts only runs on `main`, like the apply role, and the job never gets the apply role.
- **The report is public,** in the run's summary, so the scan masks hostnames, the account ID, ARNs, email and IP addresses, UUIDs and token-shaped strings, cuts log message lines short, and otherwise prints only figures and counts.
- **Claude gets no tools.** The report holds log messages, which anyone reaching Fleet can influence, so it's one request, and only Claude's text is posted, with `@mentions`, links, images, URLs and HTML broken. Only the first line counts as the verdict, so a verdict-shaped log line can't close the issue.
- **Cost:** about 10,000 tokens a scan, a few cents, once per `up`.

## 9. Optional: an Okta plan on pull requests

A pull request that changes `okta/` gets a second plan, `terraform-plan-okta`, and a comment listing which Okta resources would change and how. It never shows values: Okta's IDs and URLs aren't secrets, so GitHub wouldn't mask them, and the plan's own output stays out of the public log too. You still apply `okta/` from your terminal after merging. The check isn't required, and it skips pull requests that don't touch `okta/`.

It signs in as a second Okta service app that can only read. The one you apply with (setup guide step 6) never goes to GitHub: a pull request can change the workflow, so any credential a pull request's job can use has to be harmless.

**Set it up:**
1. **Create the app** in the Okta admin console: Applications → Create App Integration → **API Services** (Classic experience), named for example "Terraform plan (read-only)".
2. **Give it a key:** on its General tab, Client Credentials → Edit → **Public key / Private key** → Add key → Generate new key. Save the private key (Okta shows it once), and note the key ID.
3. **Okta API Scopes:** grant only `okta.apps.read` and `okta.groups.read`.
4. **Admin roles:** assign **Read-Only Administrator**.
5. **Store the four secrets** in a separate terminal (`gh secret set` prompts for each value; the key goes in from its file):
   ```bash
   gh secret set OKTA_ORG_NAME --repo $OWNER/fleet-homelab-infra
   gh secret set OKTA_PLAN_CLIENT_ID --repo $OWNER/fleet-homelab-infra
   gh secret set OKTA_PLAN_PRIVATE_KEY_ID --repo $OWNER/fleet-homelab-infra
   gh secret set OKTA_PLAN_PRIVATE_KEY --repo $OWNER/fleet-homelab-infra < path/to/the-key.pem
   ```
   Then delete the key file: only CI needs it, and Okta can generate a new one.
6. **Test it** with a pull request that changes something under `okta/`.

**Security:**
- **The key can only read** apps and groups, including who is in each group. It can't change who signs in to Fleet.
- **Forks get no secrets,** so their pull requests skip the Okta plan. Dependabot's pull requests skip it too, unless you also set the four as Dependabot secrets.
- **Only `okta.com` orgs:** the job uses the default `okta_base_url`.
