#!/usr/bin/env bash
# Copies the local hash list (the one source of truth: SHA-256 hashes with plain labels,
# no plaintext values) to the PRIVATE_HASHES secret in both repos, for Actions and
# Dependabot, so CI checks the same list as the local hooks. GitHub never shows a secret
# again, so this is the only way to update it. Change the list first with
# checks/private-values/check.py (--from-tfvars, --add LABEL, --remove LABEL); see
# checks/README.md for when.
set -euo pipefail
hashes="${FLEET_HOMELAB_PRIVATE_HASHES:-$HOME/.config/fleet-homelab/private-hashes}"
owner="${GITHUB_OWNER:-$(gh repo view --json owner --jq .owner.login)}"  # this repo's owner
repos=(fleet-homelab-infra fleet-homelab-gitops)

[ -f "$hashes" ] || { echo "No hash list at $hashes" >&2; exit 1; }
list=$(grep -E '^[[:space:]]*[0-9a-fA-F]{64}([[:space:]]|$)' "$hashes" || true)
[ -n "$list" ] || { echo "No hashes in $hashes; nothing set." >&2; exit 1; }

for repo in "${repos[@]}"; do
  for app in actions dependabot; do
    printf '%s\n' "$list" | gh secret set PRIVATE_HASHES --repo "$owner/$repo" --app "$app"
    echo "Set PRIVATE_HASHES ($app) in $owner/$repo"
  done
done
echo "$(printf '%s\n' "$list" | wc -l | tr -d ' ') hash(es) synced."
