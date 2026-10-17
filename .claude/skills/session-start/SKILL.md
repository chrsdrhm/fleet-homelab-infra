---
name: session-start
description: Start a homelab session - check sign-ins and open work, bring the stack up, verify it, and settle the nightly teardown. Run it only when the person asks, since the stack bills hourly once it's up.
disable-model-invocation: true
allowed-tools: Bash(aws sts get-caller-identity), Bash(aws rds describe-db-clusters *), Bash(aws rds describe-db-cluster-snapshots *), Bash(gh auth status), Bash(gh pr list *), Bash(gh run list *), Bash(gh run view *), Bash(gh run watch *), Bash(gh variable list *), Bash(git status *), Bash(git -C * status *), Bash(curl -s -o /dev/null *), Bash(TZ=America/Chicago date *)
---

# Start a session

Invoking this skill is the go-ahead to bring the stack up (about $0.25 an hour while it's up). Everything else here only reads, except setting `AUTO_DOWN_SKIP_UNTIL`, which needs its own yes.

The GitOps repo is assumed to sit next to this one (`../fleet-homelab-gitops`) under the same GitHub owner, as `scripts/up.sh` assumes.

## 1. Check sign-ins

- `aws sts get-caller-identity`. If the SSO session has expired, stop and ask the person to run `! aws sso login`, then carry on.
- `gh auth status`.

Never print the account ID or other identifying values in the conversation's summaries; say "signed in".

## 2. Check the state before changing anything

- **Is the stack already up?** `aws rds describe-db-clusters --db-cluster-identifier fleet-homelab` succeeds only while it is. If it's up, skip step 3 and go to step 4.
- **Is a Terraform run already going?** `gh run list --workflow terraform.yml --status in_progress` and `--status queued`. Don't start another; watch that one instead.
- **Open pull requests in both repos** (`gh pr list` in each), with their checks. Point out any in the infrastructure repo that would apply on merge once the stack is up, and anything that has to happen *before* the `up`. For example, a Fleet upgrade wants a pre-upgrade snapshot taken on the old version, so its pull request must stay unmerged until after the `up` and the snapshot (`docs/upgrading-fleet.md`).
- **Local work:** `git status` in both clones. Mention uncommitted changes or branches that aren't pushed.

## 3. Bring it up

- With CI for the infrastructure (setup guide step 8, `.github/workflows/terraform.yml`): `gh workflow run terraform.yml --ref main -f action=up`, then find the run with `gh run list --workflow terraform.yml --limit 1`.
- Without it: `./scripts/up.sh`, in the person's terminal or here.

It takes about 20-25 minutes. Watch it in the background (`gh run watch <id> --exit-status`) rather than polling, and do the step-5 check while waiting. If it fails, read the failed step's log (`gh run view <id> --log-failed`) and report the cause; `up.sh` explains the known ones (for example `InsufficientDBInstanceCapacity`). Don't retry or tear down without asking.

## 4. Verify

- The run succeeded, and its log's last lines show `/healthz -> HTTP 200` and `/ -> HTTP 200` (a 307 to `/setup` means it came up with an empty database: say so straight away).
- `up.sh` starts a GitOps run: check the newest run of `workflow.yml` in the GitOps repo passed (`gh run list --repo <owner>/fleet-homelab-gitops --workflow workflow.yml --limit 1`).
- If the stack was already up, `curl -s -o /dev/null -w '%{http_code}' https://<fleet URL>/healthz` instead. Read the URL from `terraform output -raw fleet_url` only if the person agrees; don't write it anywhere.

## 5. The nightly teardown

With CI, a check at 2am America/Chicago runs `down` if the stack is up, unless the `AUTO_DOWN_SKIP_UNTIL` repository variable is that night's date or later (`gh variable list`).

- Get the time with `TZ=America/Chicago date`. The next check is at 2:17am on the next date whose 2am hasn't passed: tomorrow's date before midnight, today's after.
- Tell the person when it will run, and ask whether they'll be working past it. Only if they say yes: `gh variable set AUTO_DOWN_SKIP_UNTIL --body <that date>` keeps the stack up through that night, and the following night's check takes it down. If the variable is already set to a past date, it's harmless; mention it can be deleted.

## 6. Report

A few lines: up (or already up) since when, restored data or not, the GitOps run's result, open pull requests and what each would do on merge, the teardown time and whether it's skipped, and what's next if the person keeps session notes.
