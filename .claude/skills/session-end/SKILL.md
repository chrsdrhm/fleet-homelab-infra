---
name: session-end
description: End a homelab session - check nothing is left half-done, tidy snapshots, tear the stack down after one confirmation, and verify it's down. Run it only when the person asks.
disable-model-invocation: true
allowed-tools: Bash(aws sts get-caller-identity --query *), Bash(aws rds describe-db-clusters --db-cluster-identifier fleet-homelab --query *), Bash(aws rds describe-db-cluster-snapshots --snapshot-type manual --query *), Bash(gh auth status), Bash(gh pr list), Bash(gh pr list *), Bash(gh run list *), Bash(gh run view *), Bash(gh run watch *), Bash(gh variable list), Bash(gh variable list *), Bash(git status), Bash(git status *), Bash(git log @{u}..), Bash(git -C ../fleet-homelab-gitops status), Bash(git -C ../fleet-homelab-gitops status *), Bash(git -C ../fleet-homelab-gitops log @{u}..), Bash(TZ=America/Chicago date), Bash(TZ=America/Chicago date *)
---

# End a session

Tearing down keeps the data: `down.sh` snapshots Aurora first, and `up` restores it. It still destroys the running stack, so **show the step-2 report and ask once ("Tear down now?") before step 4**, even though the person asked for this skill. Everything else only reads, except deleting a snapshot or the skip variable, which each need their own yes.

The GitOps repo is assumed to sit next to this one (`../fleet-homelab-gitops`) under the same GitHub owner. For it, pass `--repo <owner>/fleet-homelab-gitops` to `gh`, with the owner from this clone's remote.

**Keep identifying values out of the conversation.** Account IDs, ARNs, the Fleet URL and sign-in names must not be printed, so every AWS command below limits its output with `--query`, and nothing identifying goes into session notes.

## 1. Check sign-ins

`aws sts get-caller-identity --query 'Account != null' --output text` (if the session has expired, ask for `! aws sso login`) and `gh auth status`.

## 2. Check nothing is half-done

- **Is it up?** `aws rds describe-db-clusters --db-cluster-identifier fleet-homelab --query 'DBClusters[0].Status' --output text`. If it's already down, say so, and skip to step 3: snapshots bill while the stack is down too.
- **Runs in progress** in both repos (`gh run list --status in_progress`, and `--status queued`, with `--repo` for the GitOps repo): an apply on merge, a GitOps run, an `up`. Wait for them to finish: tearing down under an apply or a GitOps run makes it fail.
- **Open pull requests** in both repos (`gh pr list`). Say which would apply on merge if merged now, and which can wait for the next `up` (the infrastructure plan comment says ⏸️ when the stack is down). If a merge the person wants applied *now* is pending, ask before tearing down.
- **Local work:** `git status` and unpushed commits (`git log @{u}..`) in both clones.
- **Anything needing the running stack** that was planned for this session but not done, for example checking an upgrade (`docs/upgrading-fleet.md`, step 4).
- **A last health check:** offer to run `/health-scan` over the session before tearing down. Fleet's logs and metrics are destroyed with the stack, so this is the last chance to look. Only if the person wants it; it takes about a minute.

## 3. Snapshots

List the manual snapshots by name, date and size only: `aws rds describe-db-cluster-snapshots --snapshot-type manual --query 'DBClusterSnapshots[].[DBClusterSnapshotIdentifier,SnapshotCreateTime,AllocatedStorage]' --output text`.
- `fleet-homelab-teardown-*` are pruned by `down.sh` itself (it keeps the newest two).
- Anything else, such as `fleet-homelab-pre-upgrade-*`, is kept until someone deletes it, and bills while it exists. List each with its age and what it's for, and suggest deleting any whose purpose has passed (an upgrade that's been running cleanly). Delete only on an explicit yes: `aws rds delete-db-cluster-snapshot --db-cluster-snapshot-identifier <id> --query 'DBClusterSnapshot.Status' --output text`.

If the stack was already down, go to step 5.

## 4. Tear down (after the yes)

- **With CI for the infrastructure:** `gh workflow run terraform.yml --ref main -f action=down -f confirm=destroy`. Then find that run, not an older one or an apply on merge: `gh run list --workflow terraform.yml --event workflow_dispatch --limit 1 --json databaseId,createdAt,status`, and check `createdAt` is after the dispatch (try again after a few seconds if not).
- **Without it:** ask the person to run `! CONFIRM=destroy ./scripts/down.sh` themselves. Its output includes ARNs, which shouldn't pass through here.

It takes about 20 minutes. Watch it in the background (`gh run watch <id> --exit-status`). If it fails, read the failed step's log (`gh run view <id> --log-failed`), report the cause in your own words without quoting identifying values, and say plainly that the stack may be partly up and billing. Don't retry without asking.

## 5. Verify and report

- The run succeeded; the `describe-db-clusters` command above now fails with "not found"; the newest `fleet-homelab-teardown-*` snapshot is from just now.
- `AUTO_DOWN_SKIP_UNTIL` (`gh variable list`): if it's set to a date still to come, it would skip the nightly teardown if the stack comes up again before then. Recommend deleting it (`gh variable delete AUTO_DOWN_SKIP_UNTIL`), on a yes.
- A short report: down since when, the snapshot kept, open pull requests and what each will do at the next `up`, local work not pushed, and what's next. If the person keeps session notes (for example Claude's memory), update them with that, without identifying values.
