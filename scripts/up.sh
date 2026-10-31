#!/usr/bin/env bash
# Rebuilds the stack, restoring Aurora from the newest teardown snapshot (pass --fresh
# for an empty database). Finds the snapshot through the AWS API, not a local file,
# so it works the same locally and in CI.
set -euo pipefail
cd "$(dirname "$0")/.."
export AWS_REGION="${AWS_REGION:-us-east-1}" AWS_PAGER=""

if [ ! -d .terraform ]; then
  echo "Terraform is not initialized here. Run: terraform init -backend-config=backend.hcl" >&2
  echo "(backend.hcl is gitignored; copy backend.example.hcl and fill in the state bucket.)" >&2
  exit 1
fi

SNAPSHOT_ARGS=()
if [ "${1:-}" != "--fresh" ]; then
  SNAPSHOT_ID=$(aws rds describe-db-cluster-snapshots --snapshot-type manual \
    --query "sort_by(DBClusterSnapshots[?starts_with(DBClusterSnapshotIdentifier, 'fleet-homelab-teardown-')], &SnapshotCreateTime)[-1].DBClusterSnapshotIdentifier" \
    --output text)
  if [ -n "$SNAPSHOT_ID" ] && [ "$SNAPSHOT_ID" != "None" ]; then
    echo "Restoring from snapshot: $SNAPSHOT_ID (pass --fresh to start with an empty database)"
    SNAPSHOT_ARGS=(-var "rds_snapshot_identifier=$SNAPSHOT_ID")
  else
    echo "No teardown snapshot found: creating an empty database."
  fi
else
  echo "--fresh: creating an empty database."
fi

# Terraform loads terraform.tfvars itself (locally); CI passes TF_VAR_* env instead.
# ${arr[@]+"${arr[@]}"} keeps macOS bash 3.2 + `set -u` from erroring on an empty array
VAR_ARGS=(${SNAPSHOT_ARGS[@]+"${SNAPSHOT_ARGS[@]}"})
terraform plan -input=false ${VAR_ARGS[@]+"${VAR_ARGS[@]}"} -out=tfplan

# tf-apply.sh auto-retries the one known IAM role-propagation race (see that file).
LOG=$(mktemp)
set +e
./scripts/tf-apply.sh tfplan -- ${VAR_ARGS[@]+"${VAR_ARGS[@]}"} 2>&1 | tee "$LOG"
RC=${PIPESTATUS[0]}
set -e
rm -f tfplan
if [ "$RC" -ne 0 ]; then
  if grep -q InsufficientDBInstanceCapacity "$LOG"; then
    echo "" >&2
    echo "AWS has no capacity for the Aurora instance class right now (a known, temporary" >&2
    echo "problem). The stack is partly built and billing. Either re-run up.sh later, or" >&2
    echo "run down.sh, or change rds_config.instance_class in fleet.tf (same size, other" >&2
    echo "family). Do NOT change the VPC's azs on a live or partial stack." >&2
  fi
  rm -f "$LOG"; exit "$RC"
fi
rm -f "$LOG"

echo "Apply finished. Waiting for the Fleet service to stabilize..."
aws ecs wait services-stable --cluster fleet-homelab --services fleet
URL=$(terraform output -raw fleet_url)
# FLEET_CI_HEADER (CI only) gets past the WAF's US-only rule; runners can be anywhere.
HDR=()
[ -n "${FLEET_CI_HEADER:-}" ] && HDR=(-H "x-fleet-ci: $FLEET_CI_HEADER")
H=$(curl -s -o /dev/null -m 20 -w '%{http_code}' ${HDR[@]+"${HDR[@]}"} "$URL/healthz")
ROOT=$(curl -s -o /dev/null -m 20 -w '%{http_code}' ${HDR[@]+"${HDR[@]}"} "$URL/")
echo "Up. /healthz -> HTTP $H; / -> HTTP $ROOT (200 = data restored; a 307 to /setup means an empty database)."

# SSO smoke check (checks/sso-smoke.sh, if present). A warning, not a failure: the
# rebuild itself succeeded.
if [ "$H" = "200" ] && [ -x checks/sso-smoke.sh ]; then
  FLEET_CI_HEADER="${FLEET_CI_HEADER:-}" checks/sso-smoke.sh "$URL" || true
fi

# Start a GitOps run, so a config change pushed while the stack was down is applied now.
# Best effort: needs the GitHub CLI with access to that repo (locally your own login; in
# CI a GitHub App token as GH_TOKEN). NO_GITOPS=1 skips it.
# The GitOps repo is assumed to sit next to this one, under the same owner: in CI from
# GITHUB_REPOSITORY_OWNER (the job's app token can only see the GitOps repo), locally
# from this clone's GitHub remote.
owner="${GITHUB_REPOSITORY_OWNER:-$(gh repo view --json owner --jq .owner.login 2>/dev/null || echo unknown)}"
GITOPS_REPO="${GITOPS_REPO:-$owner/fleet-homelab-gitops}"
if [ "$H" = "200" ] && [ -z "${NO_GITOPS:-}" ]; then
  if command -v gh >/dev/null 2>&1 && gh workflow run workflow.yml --repo "$GITOPS_REPO" --ref main >/dev/null 2>&1; then
    echo "Started a GitOps run in $GITOPS_REPO (follow it with: gh run watch --repo $GITOPS_REPO)."
  else
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
      echo "::warning title=GitOps run not started::Check the GitHub App: the GITOPS_APP_CLIENT_ID and GITOPS_APP_PRIVATE_KEY secrets, and that the app is installed on $GITOPS_REPO with Actions write."
    fi
    echo "Could not start a GitOps run (gh missing, not logged in, or no access). Start it by hand:" >&2
    echo "  gh workflow run workflow.yml --repo $GITOPS_REPO --ref main" >&2
  fi
fi

# Start the health scan (fleet-checks.yml), as a CI up does. Locally only: in CI the
# apply job starts it, since GH_TOKEN there can only reach the GitOps repo. Best effort,
# like the GitOps run above; NO_SCAN=1 skips it.
if [ "$H" = "200" ] && [ -z "${GITHUB_ACTIONS:-}" ] && [ -z "${NO_SCAN:-}" ]; then
  if command -v gh >/dev/null 2>&1 && gh workflow run fleet-checks.yml --repo "$owner/fleet-homelab-infra" --ref main -f action=scan -f after=up >/dev/null 2>&1; then
    echo "Started a health scan (follow it with: gh run list --workflow fleet-checks.yml --limit 1)."
  else
    echo "Could not start a health scan. Start it by hand:" >&2
    echo "  gh workflow run fleet-checks.yml --ref main -f action=scan -f after=up" >&2
  fi
fi
