---
name: session-start
description: Start a homelab session - check sign-ins and open work, bring the stack up, verify it, and settle the nightly teardown. Run it only when the person asks, since the stack bills hourly once it's up.
disable-model-invocation: true
allowed-tools: Bash(aws sts get-caller-identity --query *), Bash(aws rds describe-db-clusters --db-cluster-identifier fleet-homelab --query *), Bash(gh auth status), Bash(gh pr list), Bash(gh pr list *), Bash(gh run list *), Bash(gh run view *), Bash(gh run watch *), Bash(gh variable list), Bash(gh variable list *), Bash(git status), Bash(git status *), Bash(git -C ../fleet-homelab-gitops status), Bash(git -C ../fleet-homelab-gitops status *), Bash(TZ=America/Chicago date), Bash(TZ=America/Chicago date *)
---

# Start a session

Invoking this skill is the go-ahead to bring the stack up (about $0.25 an hour while it's up). Everything else here only reads, except setting `AUTO_DOWN_SKIP_UNTIL`, which needs its own yes.

The GitOps repo is assumed to sit next to this one (`../fleet-homelab-gitops`) under the same GitHub owner, as `scripts/up.sh` assumes. For it, pass `--repo <owner>/fleet-homelab-gitops` to `gh`, with the owner from this clone's remote.

**Keep identifying values out of the conversation.** Account IDs, ARNs, the Fleet URL and sign-in names must not be printed, so every AWS command below limits its output with `--query`, and nothing identifying goes into session notes.

## 1. Check sign-ins

- `aws sts get-caller-identity --query 'Account != null' --output text` prints `True` when signed in. If the SSO session has expired, stop and ask the person to run `! aws sso login`, then carry on.
- `gh auth status`.

## 2. Check the state before changing anything

- **Is the stack already up?** `aws rds describe-db-clusters --db-cluster-identifier fleet-homelab --query 'DBClusters[0].Status' --output text` succeeds only while it is (or while it's being built). If it's up, skip step 3 and go to step 4.
- **Notices:** open issues titled "The teardown failed", "Kept snapshots older than 14 days" or "A newer Fleet release is available" (`gh issue list`). A failed teardown comes first: the stack may be partly up and billing, so read the linked run and sort it out before anything else (the next successful `down` closes the issue). The snapshot issue closes itself once those snapshots are deleted; the release issue, once an upgrade merges (`/fleet-upgrade`).
- **Did last night's check tear the stack down?** A successful nightly teardown sends no notice; it only marks its run with a "Stack left up" warning. Look at the newest nightly runs (`gh run list --workflow terraform.yml --event schedule --limit 2 --json databaseId,createdAt,conclusion`) and, for one that succeeded, whether its **Down** step ran (`gh run view <id> --json jobs --jq '.jobs[].steps[] | select(.name == "Down") | .conclusion'` says `success` rather than `skipped`). If it did, tell the person the stack had been left up and was torn down at 2am.
- **Is a Terraform run already going?** `gh run list --workflow terraform.yml --status in_progress` and `--status queued`. Don't start another; watch that one instead.
- **Open pull requests in both repos** (`gh pr list`, and with `--repo` for the GitOps repo), with their checks. Point out any in the infrastructure repo that would apply on merge once the stack is up.
- **A Fleet upgrade pull request:** `docs/upgrading-fleet.md` allows two orders. Merged while the stack is down, the next `up` restores the newest teardown snapshot and migrates it, and that snapshot is the restore point. Or leave it unmerged, bring the stack up on the old version, take a pre-upgrade snapshot (runbook step 2), then merge. Ask the person which they want before the `up`.
- **Local work:** `git status` in both clones. Mention uncommitted changes or branches that aren't pushed.

## 3. Bring it up

- **With CI for the infrastructure** (setup guide step 8, `.github/workflows/terraform.yml`): `gh workflow run terraform.yml --ref main -f action=up`. Then find that run, not an older one or an apply on merge: `gh run list --workflow terraform.yml --event workflow_dispatch --limit 1 --json databaseId,createdAt,status`, and check `createdAt` is after the dispatch (try again after a few seconds if not).
- **Without it:** ask the person to run `! ./scripts/up.sh` themselves. Its output includes the Fleet URL and ARNs, which shouldn't pass through here.

It takes about 20-25 minutes. Watch it in the background (`gh run watch <id> --exit-status`) rather than polling, and do step 5 while waiting. If it fails, read the failed step's log (`gh run view <id> --log-failed`) and report the cause in your own words, without quoting identifying values; `up.sh` explains the known failures (for example `InsufficientDBInstanceCapacity`). Don't retry or tear down without asking.

## 4. Verify

- The run succeeded, and its log's summary line shows `/healthz -> HTTP 200` and `/ -> HTTP 200`. A 307 to `/setup` means it came up with an empty database: say so straight away.
- `up.sh` starts a GitOps run. Find the newest `workflow.yml` run in the GitOps repo (`gh run list --repo <owner>/fleet-homelab-gitops --workflow workflow.yml --limit 1`), and if it's still going, watch it to the end before reporting.
- If the stack was already up, ask before checking it over HTTP, and keep the URL out of the command line: `curl -s -o /dev/null -w '%{http_code}' "$(terraform output -raw fleet_url)/healthz"`.

## 5. The nightly teardown

With CI, a scheduled check runs `down` at 2am America/Chicago if the stack is up, unless the `AUTO_DOWN_SKIP_UNTIL` repository variable is that night's date or later (`gh variable list`). GitHub can start it late; it still acts until 5:59am.

- Get the time with `TZ=America/Chicago date`. The next check is the next 2am: tomorrow's date before midnight, today's after midnight. Between 2am and 6am tonight's check may still be pending: look at `gh run list --workflow terraform.yml --event schedule --limit 2`. If tonight's run has already finished, the next one is tomorrow's.
- Tell the person when it will run, and ask whether they'll be working past it. Only if they say yes: `gh variable set AUTO_DOWN_SKIP_UNTIL --body <that date>` keeps the stack up through that night, and the following night's check takes it down.
- If the variable is set to a date that's still to come but no longer wanted, mention it: it would skip a teardown on a later session. Delete it only on a yes (`gh variable delete AUTO_DOWN_SKIP_UNTIL`).

## 6. Report

A few lines: up (or already up) since when, restored data or not, the GitOps run's result, open pull requests and what each would do on merge, the teardown time and whether it's skipped, and what's next. If the person keeps session notes, add the same, without identifying values.
