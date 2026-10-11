# GitHub setup

The GitHub side of both repos: secrets, repository settings, branch rules, a label and an optional GitHub App. It's part of the [setup guide](setup.md) (steps 7 and 8). Run the commands from anywhere the GitHub CLI is signed in. Set `OWNER` first:

```bash
OWNER=$(gh api user --jq .login)
```

Do the steps in this order. The branch rules require checks that must have run at least once; a required check that has never run blocks every merge.

## 1. Secrets

`gh secret set NAME --repo $OWNER/<repo>` prompts for the value, so it stays out of your shell history. Add `--app dependabot` to set the Dependabot copy: Dependabot's pull requests can only read Dependabot secrets.

**`fleet-homelab-infra`:**

| Secret | Value | Also for Dependabot |
|---|---|---|
| `AWS_ROLE_ARN` | `terraform output -raw github_actions_apply_role_arn` | |
| `AWS_PLAN_ROLE_ARN` | `terraform output -raw github_actions_plan_role_arn` | yes |
| `TF_STATE_BUCKET` | Your state bucket's name | yes |
| `FLEET_SUBDOMAIN`, `FLEET_LICENSE_KEY`, `BUDGET_ALERT_EMAIL`, `WAF_CI_HEADER_VALUE` | The same values as in `terraform.tfvars` | yes |
| `CLOUDFLARE_ZONE_NAME`, `CLOUDFLARE_API_TOKEN` | The same as in `terraform.tfvars`; skip both if your DNS isn't on Cloudflare | yes |
| `GITOPS_APP_CLIENT_ID`, `GITOPS_APP_PRIVATE_KEY` | Optional, from the GitHub App in step 5 | |
| `PRIVATE_HASHES` | Set by `checks/private-values/sync-hashes.sh` (see [`checks/README.md`](../checks/README.md#private-values)) | yes (the script sets both) |
| `CLAUDE_CODE_OAUTH_TOKEN` | Optional, for Claude reviews (step 6) | |

**`fleet-homelab-gitops`:**

| Secret | Value |
|---|---|
| `FLEET_URL` | `https://<fleet_subdomain>` |
| `FLEET_API_TOKEN` | The GitOps API user's token ([setup guide step 7](setup.md#7-the-gitops-repo-fleets-configuration)) |
| `FLEET_CI_HEADER` | Your `waf_ci_header_value` |
| `FLEET_OKTA_METADATA_URL`, `FLEET_IDP_IMAGE_URL` | Only with Okta: `terraform output -raw metadata_url` (in `okta/`) and `terraform output -raw idp_logo_url` |
| `PRIVATE_HASHES` | Set by `sync-hashes.sh`, which also sets the Dependabot copy |
| `CLAUDE_CODE_OAUTH_TOKEN` | Optional, for Claude reviews (step 6) |

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

## 3. Run the checks once

Open a small pull request in each repo, such as a one-line README edit, and let its checks run. This registers the check names (`terraform-lint` and `terraform-plan` in infra; `fleet-gitops` and `gitops-lint` in GitOps), which the branch rules in the next step require. Merge or close the pull requests afterwards.

## 4. Branch rules

A ruleset named `protect-main` on the default branch, with no bypass, not even for you:
- every change goes through a pull request whose required checks pass
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
    { "type": "required_status_checks", "parameters": { "strict_required_status_checks_policy": false,
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

`.github/workflows/claude-review.yml` in each repo asks Claude to review every pull request when it's opened, reopened or marked ready. It follows `AGENTS.md`'s review section and posts inline comments plus one summary comment with a ✅ / ⚠️ / ❌ verdict. The summary is updated in place on later runs, not added again. **It needs a Claude Pro or Max subscription.** Reviews count against your plan's usage, with no separate bill. Without the token, the job skips with a notice. It's never a required check.

**How it signs in.** There are two separate sign-ins:
- **To Claude, with a one-year token from your subscription.**
  - **Creating it:** `claude setup-token` signs in to claude.ai in your browser and prints the token once; it isn't saved anywhere on your machine.
  - **What it can do:** only make model requests. It can't open your chats, change your account, or use connectors.
  - **Where it lives:** you store it as the encrypted `CLAUDE_CODE_OAUTH_TOKEN` secret. GitHub hands it only to workflow runs in that repo, never to forks or Dependabot, and masks it in logs.
  - **During a review:** Claude Code on the runner uses it for its requests, and the usage counts against your plan's limits, with no separate bill.
- **To GitHub, with the job's own token.** It's created for each run and expires when the run ends. It can read the repo and comment on the pull request, nothing else. Comments appear as `github-actions[bot]`. No GitHub App and no OIDC are involved.
- **Who could read the secret:** any workflow running in the repo can, so it's only as safe as who can change workflows: here, only you, through pull requests.
- **Stopping it:** delete the secret.
- **After a year:** the token stops working, and the review job then fails (it isn't required, so merges aren't blocked) until you create a new token.
- **What it can look at:** the repo, plus Fleet's docs and GitHub, so it can compare a change with Fleet's own approach (see `AGENTS.md`).

**How much it uses:**
- **Per review:** expand **📊 Usage summary** at the end of the summary comment. The review's run in the Actions tab shows the same figures, plus a list-price estimate (not billed on a subscription).
- **What the numbers mean:**
  - **Input tokens:** how much text Claude read: the diff, files, `AGENTS.md`, any pages it fetched, and the conversation so far, which is sent again on every turn. That is why this number is large. Most of it is "read from cache": text it already sent, which costs about a tenth as much at API prices.
  - **Output tokens:** what Claude wrote, its reasoning and comments. A token is roughly ¾ of a word.
  - **Turns:** rounds of Claude using a tool, such as reading a file or fetching a page. More turns means it dug deeper.
  - **Duration:** how long the review took.
- **A lot or a little?** A small pull request here takes about 100,000 input tokens (most of it cached), 1,000–2,000 output tokens, 4–5 turns and under a minute: about $0.10 at API list prices. A large change can be several times that. The list-price estimate is the easiest way to compare reviews.
- **Your plan overall:** see **claude.ai → Settings → Usage**, or `/usage` in Claude Code. Reviews draw on the same plan limits as your own sessions. To see what one review costs your plan, check that page before and after it.

**Model:** your plan's default. To pin one, set a repository variable, for example:
```bash
gh variable set CLAUDE_REVIEW_MODEL --body claude-sonnet-5-5 --repo $OWNER/fleet-homelab-infra
```

1. Create a token from your subscription. Run this in a terminal, not through an AI assistant, because it prints the token:
   ```bash
   claude setup-token
   ```
2. Store it in both repos (the command prompts for the value):
   ```bash
   gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo $OWNER/fleet-homelab-infra
   gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo $OWNER/fleet-homelab-gitops
   ```
3. Make sure both actions it needs are in the allow-list (step 2).
4. Put a reminder in your calendar: the token expires after a year. Then run `claude setup-token` again and update both secrets.

**To review again** after pushing changes, comment `@claude` on the pull request. Claude reviews the latest commit, reacts with 👀 when it starts, and updates the same summary comment.
- **Only your comments trigger it.** Anyone can comment on a public repo, and each review uses your plan, so a mention from anyone but the repo owner is ignored.
- **Drafts:** skipped when opened, but `@claude` reviews one anyway.
- **Forks and Dependabot:** their pull requests never get the token on their own, so they're never sent to Claude automatically. Commenting `@claude` on one does send it. Claude only reads the code, never runs it.
- **What the job can do:** read the repo and comment on the pull request, nothing else.

Re-running the workflow from the Checks tab reviews the commit it first ran on, not your latest push.

### Using a different reviewer, or none

The review is optional and swappable. The instructions any reviewer should follow are in `AGENTS.md`, which most AI tools read as-is, so switching doesn't change them.

- **No AI review:** do nothing. Without the `CLAUDE_CODE_OAUTH_TOKEN` secret, the Claude job skips itself. To remove it entirely, delete `.github/workflows/claude-review.yml` and the two allow-list entries it needed (`anthropics/claude-code-action@*` and `oven-sh/setup-bun@*`).
- **GitHub Copilot:** this needs Copilot Pro or higher. Copilot Free can't review pull requests, and each review uses Copilot AI credits.
  - Turn it on with the ruleset setting **Automatically request Copilot code review**: Settings → Rules → Rulesets → `protect-main`.
  - Nothing else changes: Copilot reads `AGENTS.md`, and needs no workflow, secret or allow-list entry.
  - Remove the Claude workflow, or leave it in place without its token.
- **Another review tool or GitHub Action:**
  - **A GitHub App** (installed from its own site or the Marketplace): follow its instructions. Give it only the repositories and permissions it asks for.
  - **A GitHub Action:**
    - Pin it to a full commit SHA.
    - Add it, and any action it uses internally, to the allow-list in step 2.
    - Store its credential as a secret, and keep its permissions to reading the repo and commenting on pull requests.
  - **Instructions:** most tools read `AGENTS.md`. If one doesn't, point it there rather than copying the rules.
