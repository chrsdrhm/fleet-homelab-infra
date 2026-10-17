---
name: session-end
description: End a homelab session - check nothing is left half-done, tidy snapshots, tear the stack down after one confirmation, and verify it's down. Run it only when the person asks.
disable-model-invocation: true
allowed-tools: Bash(aws sts get-caller-identity), Bash(aws rds describe-db-clusters *), Bash(aws rds describe-db-cluster-snapshots *), Bash(gh auth status), Bash(gh pr list *), Bash(gh run list *), Bash(gh run view *), Bash(gh run watch *), Bash(gh variable list *), Bash(git status *), Bash(git -C * status *), Bash(git -C * log *), Bash(TZ=America/Chicago date *)
---

# End a session

Tearing down keeps the data: `down.sh` snapshots Aurora first, and `up` restores it. It still destroys the running stack, so **show the step-2 report and ask once ("Tear down now?") before step 4**, even though the person asked for this skill. Everything else only reads, except deleting a snapshot, which needs its own yes.

The GitOps repo is assumed to sit next to this one (`../fleet-homelab-gitops`) under the same GitHub owner.

## 1. Check sign-ins

`aws sts get-caller-identity` (if expired, ask for `! aws sso login`) and `gh auth status`. Never print the account ID or other identifying values.

## 2. Check nothing is half-done

- **Is it up?** `aws rds describe-db-clusters --db-cluster-identifier fleet-homelab`. If it's already down, say so and skip to step 5.
- **Runs in progress** in both repos (`gh run list --status in_progress`, and `--status queued`): an apply on merge, a GitOps run, an `up`. Wait for them to finish: tearing down under an apply or a GitOps run makes it fail.
- **Open pull requests** in both repos (`gh pr list`). Say which would apply on merge if merged now, and which can wait for the next `up` (the infrastructure plan comment says ⏸️ when the stack is down). If a merge the person wants applied *now* is pending, ask before tearing down.
- **Local work:** `git status` and unpushed commits (`git -C <repo> log @{u}..`) in both clones.
- **Anything needing the running stack** that was planned for this session but not done, for example checking an upgrade (`docs/upgrading-fleet.md`, step 4).

## 3. Snapshots

List the manual snapshots: `aws rds describe-db-cluster-snapshots --snapshot-type manual` (identifier, creation time, size).
- `fleet-homelab-teardown-*` are pruned by `down.sh` itself (it keeps the newest few).
- Anything else, such as `fleet-homelab-pre-upgrade-*`, is kept until someone deletes it, and bills while it exists. List each with its age and what it's for, and suggest deleting any whose purpose has passed (an upgrade that's been running cleanly). Delete only on an explicit yes: `aws rds delete-db-cluster-snapshot --db-cluster-snapshot-identifier <id>`.

## 4. Tear down (after the yes)

- With CI for the infrastructure: `gh workflow run terraform.yml --ref main -f action=down -f confirm=destroy`, then find the run with `gh run list --workflow terraform.yml --limit 1`.
- Without it: `CONFIRM=destroy ./scripts/down.sh`.

It takes about 20 minutes. Watch it in the background (`gh run watch <id> --exit-status`). If it fails, read the failed step's log (`gh run view <id> --log-failed`), report the cause, and say plainly that the stack may be partly up and billing. Don't retry without asking.

## 5. Verify and report

- The run succeeded; `describe-db-clusters` for `fleet-homelab` now fails (not found); the newest `fleet-homelab-teardown-*` snapshot is from just now.
- `AUTO_DOWN_SKIP_UNTIL` (`gh variable list`): if it's set to a future date, it does nothing while the stack is down; mention it can be deleted (`gh variable delete AUTO_DOWN_SKIP_UNTIL`), but don't delete it unasked.
- A short report: down since when, the snapshot kept, open pull requests and what each will do at the next `up`, local work not pushed, and what's next. If the person keeps session notes (for example Claude's memory), update them with that.
