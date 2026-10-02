#!/usr/bin/env bash
# Wraps `terraform apply` with one automatic retry for a known, reproducible
# IAM role-propagation race: a role created earlier in the SAME apply (the
# Fleet module's `fleet-role`) isn't always visible yet to the policy
# attachment that follows moments later. This is AWS IAM's own eventual
# consistency, not a Terraform/provider bug, and the AWS provider does not
# auto-retry it: NoSuchEntity is a genuine 404, not a throttling error the
# SDK's retry logic recognizes. Hit on 3 of 3 real builds of this stack
# (initial build, two rebuilds including a snapshot restore) — always on the
# same resource, always fixed by re-planning and re-applying a few seconds
# later, once IAM has caught up. A `-target` of just the role beforehand
# doesn't reliably help either: the role and its attachment are often
# created back-to-back late in a long apply, so elapsed time from the start
# of the whole apply isn't the same as elapsed time since the role itself
# was created.
#
# Usage: scripts/tf-apply.sh <saved-plan-file> -- <var args to reuse on retry>
#   e.g. scripts/tf-apply.sh tfplan -- -var-file=terraform.tfvars
#   e.g. scripts/tf-apply.sh tfplan -- -var-file=terraform.tfvars -var rds_snapshot_identifier=foo
#
# The retry can't just reapply the same saved plan file — Terraform refuses
# a saved plan once state has moved on from a partial apply ("Saved plan is
# stale") — so it re-plans and applies fresh instead, with the same vars.
set -euo pipefail

PLAN_FILE="$1"; shift
if [ "${1:-}" = "--" ]; then shift; fi
RETRY_ARGS=("$@")

OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT

if terraform apply -no-color -auto-approve "$PLAN_FILE" 2>&1 | tee "$OUT"; then
  exit 0
fi

if grep -qE "NoSuchEntity: The role with name .* cannot be found" "$OUT"; then
  echo
  echo "== IAM role-propagation race detected (role not yet visible to AttachRolePolicy). =="
  echo "== Waiting 20s, then re-planning and applying the remainder. =="
  sleep 20
  exec terraform apply -auto-approve "${RETRY_ARGS[@]}"
fi

echo "Apply failed for a reason other than the known IAM race; not retrying." >&2
exit 1
