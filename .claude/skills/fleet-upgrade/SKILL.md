---
name: fleet-upgrade
description: Upgrade the self-hosted Fleet server - review the releases in between against this setup, take the pre-upgrade snapshot, open (or review) the upgrade pull request, and check the result after the merge. Run it only when the person asks.
disable-model-invocation: true
allowed-tools: Bash(gh release list *), Bash(gh release view *), Bash(gh api repos/fleetdm/fleet/git/trees/*), Bash(gh api repos/fleetdm/fleet/contents/*), Bash(gh api repos/fleetdm/fleet-terraform/tags), Bash(gh pr list), Bash(gh pr list *), Bash(gh pr view *), Bash(gh pr checks *), Bash(gh pr diff *), Bash(gh run list *), Bash(gh run view *), Bash(gh run watch *), Bash(aws sts get-caller-identity --query *), Bash(aws rds describe-db-clusters --db-cluster-identifier fleet-homelab --query *), Bash(aws ecs describe-services --cluster fleet-homelab --services fleet --query *), Bash(aws ecs describe-task-definition --task-definition fleet --query *), Bash(aws logs describe-log-groups --log-group-name-prefix terraform- --query *), Bash(aws logs start-query *), Bash(aws logs get-query-results *), Bash(git status), Bash(git diff *), Bash(TZ=America/Chicago date)
---

# Upgrade Fleet

This skill runs the routine in [`docs/upgrading-fleet.md`](../../../docs/upgrading-fleet.md), which stays the manual way to do it. Read the runbook first; where they differ, the runbook wins and this skill should be fixed.

Invoking the skill asks for a review and a plan. **Each step that changes something needs its own yes**: bringing the stack up (it bills), the snapshot (it bills until deleted), pushing a branch and opening the pull request. **Merging is the person's call**; never merge. Never run a rollback without a yes.

**Keep identifying values out of the conversation.** Every AWS command limits its output with `--query`; don't print the Fleet URL, account IDs or ARNs, and don't quote run logs that contain them.

## 1. Versions

- **Current:** the `FROM fleetdm/fleet:vX.Y.Z` line in `fleet.Dockerfile` (`fleet.tf` reads it). If the stack is up, also check what's running: `aws ecs describe-task-definition --task-definition fleet --query 'taskDefinition.containerDefinitions[0].image' --output text`.
- **Target:** what the person names, or the newest release: `gh release list --repo fleetdm/fleet --limit 30`, keeping only `fleet-v*` tags (the repo also publishes agent releases). If the nightly "A newer Fleet release is available" issue is open, it names one.
- **Every release in between, patch releases included:** both the target's line and any patches on the current line (for example 4.92.1 to 4.92.3 when going from 4.92.0 to 4.93.0).
- **The image exists:** `fleetdm/fleet:v<target>` on Docker Hub (`https://hub.docker.com/v2/repositories/fleetdm/fleet/tags/v<target>`).

## 2. Review the releases

Read each release's notes (`gh release view fleet-vX.Y.Z --repo fleetdm/fleet`) and Fleet's `CHANGELOG.md`. Check them against this setup, and say what you checked:

- **Server configuration:** the `FLEET_*` environment variables in `fleet.tf`, renamed or removed settings, changed defaults.
- **Database and cache:** a new minimum MySQL or Redis version, against Aurora's engine version (`aws rds describe-db-clusters ... --query 'DBClusters[0].EngineVersion'`) and ElastiCache's.
- **`fleet-terraform`:** newer `tf-mod-root-*` and add-on tags (`gh api repos/fleetdm/fleet-terraform/tags`), and whether the release needs them. Bump them in the same pull request only if it does; otherwise they're a separate change.
- **The GitOps repo** (`../fleet-homelab-gitops`): renamed or removed YAML keys it uses, and anything the dry run would now reject.
- **CI:** the GitOps workflow installs the `fleetctl` that matches the server, so a new server version means a new `fleetctl` on the next run.
- **Fleet's `fleetctl new` template**, which the GitOps repo's layout and `.github/fleet-gitops/` come from. Compare from the template version the GitOps repo records it matches (a `fleet-template: vX.Y.Z` line, per plan Task 25 Step 6), or, until it records one, from the current server version. List the template files' blob hashes at that tag and the target (`gh api "repos/fleetdm/fleet/git/trees/fleet-vX.Y.Z?recursive=1"`, filtering paths under `cmd/fleetctl/fleetctl/templates/new/`), and diff any file whose hash changed. If the GitOps repo adopts the changes, update its recorded version in the same pull request (`gh api "repos/fleetdm/fleet/contents/<path>?ref=<tag>"`). Say what changed and whether the GitOps repo should adopt it; it deliberately differs in places (it installs `fleetctl` from the GitHub release with a checksum check, not through `curl | bash`).

If the nightly "A newer Fleet release is available" issue carries Claude's review (plan Task 38), start from it, but check it: it saw only the release notes, the template and the two repos' files.

Then report, briefly, sorted the same way as that review, leaving out a group with nothing in it:
1. **Breaking:** what stops working or behaves differently here: removed or renamed settings, variables, YAML keys or flags these repos use, changed defaults, new minimum versions, migrations that need care.
2. **Must change:** edits either repo needs before or with the upgrade, with the file and the change.
3. **Deprecated, still works:** what these repos do that still works but that Fleet now does a new way (a renamed key that still accepts the old name, a moved setting, a new template field), with the suggested change. Worth doing in the upgrade pull request or soon after.
4. **New and relevant:** new features touching what we use (Windows MDM, Okta and end-user authentication, GitOps, the AWS modules) that might be worth adopting.

And a verdict: ✅ upgrade as is, ⚠️ upgrade with these changes, or ❌ wait (say why, for example a regression reported in Fleet's issues). If a release note is unclear, say so and link it; don't guess.

## 3. Choose the order

Check whether the stack is up (`aws rds describe-db-clusters --db-cluster-identifier fleet-homelab --query 'DBClusters[0].Status' --output text`), and ask which order the person wants. The runbook allows both:

- **Snapshot first (preferred while there's data worth keeping):** with the stack up on the current version (bring it up with `/session-start` if needed, and don't merge the upgrade pull request before then: an `up` after the merge restores and migrates in one go, leaving no point to snapshot), take the snapshot (step 4), then merge.
- **Merge while down:** the newest teardown snapshot is the restore point, and the next `up` migrates. Quicker; that snapshot is pruned after two more teardowns, so take a manual copy if the rollback window matters.

## 4. Snapshot (on a yes)

```bash
SNAP=fleet-homelab-pre-upgrade-$(date -u +%Y%m%d%H%M%S)
aws rds create-db-cluster-snapshot --db-cluster-identifier fleet-homelab --db-cluster-snapshot-identifier "$SNAP" --query 'DBClusterSnapshot.Status' --output text
aws rds wait db-cluster-snapshot-available --db-cluster-snapshot-identifier "$SNAP"
```

It takes about five minutes for a small database. Tell the person its name; `down.sh` never prunes it, and `/session-end` offers to delete it later.

## 5. The pull request

- **Open one (on a yes),** or review it if the person already has: a branch from an up-to-date `origin/main`, the tag change in `fleet.Dockerfile`, and anything step 2 requires. The body summarizes step 2: releases reviewed, nothing required or what's required, the expected plan, and the rollback. The repo's commit and pull request conventions are in `AGENTS.md`.
- **Before the merge, the plan must be against the stack as it is now.** A pull request opened while the stack was down shows ⏸️ and a plan for a full build; one that's behind `main` can't merge (the ruleset requires branches to be up to date). Either way, update the branch with `main` (`gh pr update-branch <number>`, on a yes) once the stack is up and the snapshot is taken, and wait for the new plan.
- **Expected plan:** the Fleet task definition and `module.migrations.null_resource.main` replaced, the ECS service updated, and nothing that holds data destroyed. Anything else needs explaining before the merge.

Then tell the person it's ready to merge, and what happens: the apply on merge stops Fleet, runs `fleet prepare db` on the new version, and starts it again, about 8 minutes in all, with Fleet unavailable for part of it.

## 6. Check after the merge

- **The apply:** find the **Terraform apply on merge** run for the merge commit (`gh run list --workflow terraform.yml --event push --limit 1`), watch it to the end, and check it reports the planned resource counts.
- **The service:** `aws ecs describe-services --cluster fleet-homelab --services fleet --query 'services[0].[runningCount,desiredCount,deployments[0].rolloutState]' --output text` shows `1 1 COMPLETED`, and the task definition's image is the target.
- **The migrations and errors,** in Fleet's log group (`aws logs describe-log-groups --log-group-name-prefix terraform- --query 'logGroups[0].logGroupName' --output text`) with Logs Insights over the last 45 minutes:
  - `fields @timestamp, @message | filter @message like /Missing migrations/ or @message like /\[20\d\d-\d\d-\d\d\]/ | sort @timestamp asc` lists the migrations `fleet prepare db` ran.
  - `filter level in ["error","warn"] or @message like /(?i)panic|fatal/ | stats count(*), min(@timestamp), max(@timestamp) by level, msg` sums up errors. `unlock failed` with `context canceled` while the old task shuts down is expected (plan Task 21's baseline); anything else needs a look.
  - Once plan Task 30's health-scan skill exists, run it as well.
- **The version, through GitOps:** start a GitOps run (`gh workflow run workflow.yml --repo <owner>/fleet-homelab-gitops --ref main`, on a yes), watch it, and check its log says `Installing fleetctl v<target>` with the checksum `OK`: the workflow reads the server's version to choose `fleetctl`, so this confirms the server reports the target, without handling an API token here.

## 7. If a check fails

Say what failed, and set out the runbook's **Rolling back** section: revert the upgrade pull request, `down`, then rebuild from the pre-upgrade snapshot with `rds_snapshot_identifier`. Anything recorded since the snapshot is lost with it (including MDM enrollments and escrowed keys). Run none of it without a yes, and consider first whether a fix forward (a patch release) is the better answer.

## 8. Wrap up

Report the result in a few lines: the version now running, the migrations run, the errors seen (if any), the GitOps result, and the snapshot kept. Suggest keeping the snapshot for a few sessions, then deleting it (`/session-end` offers to). If the runbook turned out wrong or unclear anywhere, fix `docs/upgrading-fleet.md` in a pull request.
