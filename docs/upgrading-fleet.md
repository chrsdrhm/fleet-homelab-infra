# Upgrading Fleet

Fleet is self-hosted here, so upgrades are yours to do. Fleet releases about every three weeks; watch [Fleet's releases](https://github.com/fleetdm/fleet/releases) (Watch → Custom → Releases on GitHub) to hear about them. The version is the image tag in `fleet.Dockerfile`. With CI, the daily release check also opens an issue, "A newer Fleet release is available", once a release has been out for a week, and closes it when `fleet.Dockerfile` catches up. (Dependabot can't do this one: `fleetdm/fleet` has tens of thousands of image tags, and its check never finishes.)

With [Claude Code](https://claude.com/claude-code), `/fleet-upgrade` (in `.claude/skills/`) runs this routine with you: it reviews the releases in between against this setup, takes the snapshot, opens the pull request and checks the result, asking before each step that changes something. This page is the manual way.

An upgrade is a one-line pull request. On merge, the change is applied (if the stack is down, at the next `up`), and the migrations add-on stops Fleet, runs `fleet prepare db` on the new version, and starts it again. Expect a few minutes of downtime. **Database migrations can't be undone**, so take a snapshot first; it's the way back.

## 1. Read the release notes

From the version in `fleet.Dockerfile` (`FROM fleetdm/fleet:vX.Y.Z`) to the target, read every release in between, in [Fleet's releases](https://github.com/fleetdm/fleet/releases) and its [changelog](https://github.com/fleetdm/fleet/blob/main/CHANGELOG.md). Look for:
- **Breaking changes** and renamed or removed settings, especially in the [GitOps YAML](https://fleetdm.com/docs/configuration/yaml-files), which the GitOps repo uses.
- **New minimum versions** of MySQL or Redis.
- **Server configuration changes** for the environment variables in `fleet.tf`.
- **Deprecations:** things the GitOps repo or `fleet.tf` does that still work but that Fleet now does a new way, such as a renamed key that still accepts the old name. Not urgent, but easier to adopt with the upgrade than after the old way is removed.
- **Changes to Fleet's GitOps template** (what `fleetctl new` writes), which the GitOps repo's layout and `.github/fleet-gitops/` come from.

With CI, the daily release issue also carries a first review by Claude ([GitHub setup step 7](github-setup.md#7-optional-claude-reviews-new-fleet-releases)): the releases in between checked against this setup, sorted into **Breaking**, **Must change**, **Deprecated, still works** and **New and relevant**, with a ✅ / ⚠️ / ❌ verdict. It's a head start, not a substitute: it sees only the release notes, the template and the two repos' files, so read anything it marks before upgrading. `/fleet-upgrade` does the full review, in the same four groups.

Skipping releases is fine; migrations run in order. Also check [`fleet-terraform`](https://github.com/fleetdm/fleet-terraform/tags) for newer `tf-mod-root-*` and add-on tags: their changelogs say which Fleet version they target and what changed. Bump those in the same pull request only if the release needs it; otherwise they're a separate change.

## 2. Snapshot the database

If the stack is up, snapshot Aurora (if it's down, the teardown snapshot is already your restore point):

```bash
SNAP=fleet-homelab-pre-upgrade-$(date -u +%Y%m%d%H%M%S)
aws rds create-db-cluster-snapshot --db-cluster-identifier fleet-homelab --db-cluster-snapshot-identifier "$SNAP"
aws rds wait db-cluster-snapshot-available --db-cluster-snapshot-identifier "$SNAP"
```

`down.sh` only prunes `fleet-homelab-teardown-*` snapshots, so this one stays until you delete it. Delete it once the new version has run cleanly for a while; it bills while it exists. With CI, the nightly run lists it in a "Kept snapshots older than 14 days" issue once it's two weeks old, as a reminder.

## 3. The pull request

Change the tag in `fleet.Dockerfile`, for example `fleetdm/fleet:v4.92.0` → `fleetdm/fleet:v4.93.0`, plus anything the release notes call for. The pull request's plan should show the Fleet task definition and the migrations add-on replaced and the ECS service updated, with nothing that holds data destroyed. If the stack is down, the plan still works; it describes what the next `up` will do.

Before merging, make sure the plan is against the stack as it is now. If the stack came up after the pull request was opened, or the branch is behind `main` (branches must be up to date to merge), select **Update branch** and wait for the new plan.

## 4. Merge, and check it

- **Stack up:** the merge applies it. Watch the **Terraform apply on merge** run in the Actions tab.
- **Stack down:** nothing happens until the next `up`, which restores the latest snapshot and migrates it.

Then check:
- The server reports the new version. In a separate terminal, with your Fleet API token: `curl -s -H "Authorization: Bearer $TOKEN" https://<fleet_subdomain>/api/v1/fleet/version | jq .version`
- Hosts are checking in, and Fleet's logs show no errors. `scripts/health-scan.sh 2` gathers the figures for the last two hours (ECS, the logs grouped by message, the load balancer, Aurora and the rest), and [`.claude/skills/health-scan/baseline.md`](../.claude/skills/health-scan/baseline.md) says what's normal; with Claude Code, `/health-scan` runs it and compares.
- The GitOps repo's next run passes. It installs the `fleetctl` that matches the server automatically, so start one to be sure: `gh workflow run workflow.yml --repo <you>/fleet-homelab-gitops`.

## Rolling back

Rolling back means restoring the pre-upgrade snapshot with the old version:
1. Tear down first, with `./scripts/down.sh`. Reverting while the stack is up would roll the old version onto the already-migrated database. Its new teardown snapshot holds the upgraded database, so don't restore from it.
2. Revert the upgrade pull request, so `fleet.Dockerfile` has the old tag again. With the stack down, the merge doesn't touch Fleet. The release check will flag the newer release again; leave that unmerged until the problem is fixed.
3. Rebuild from the pre-upgrade snapshot instead of the newest teardown one:
   ```bash
   terraform plan -input=false -var rds_snapshot_identifier="$SNAP" -out=tfplan
   ./scripts/tf-apply.sh tfplan -- -var rds_snapshot_identifier="$SNAP"
   ```

Anything recorded between the upgrade and the rollback is lost with it.
