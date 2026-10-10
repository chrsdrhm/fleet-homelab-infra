#!/usr/bin/env bash
# Copies the local private-strings file (the one source of truth) to the PRIVATE_STRINGS
# secret in both repos, in both the Actions and Dependabot stores, so the CI checks and
# the local hooks use the same list. Nothing is printed except where it was set.
# Run after editing ~/.config/fleet-homelab/private-strings (or FLEET_HOMELAB_PRIVATE_STRINGS).
set -euo pipefail
patterns="${FLEET_HOMELAB_PRIVATE_STRINGS:-$HOME/.config/fleet-homelab/private-strings}"
owner="${GITHUB_OWNER:-chrsdrhm}"
repos=(fleet-homelab-infra fleet-homelab-gitops)

[ -f "$patterns" ] || { echo "No patterns file at $patterns" >&2; exit 1; }
values=$(grep -v -E '^[[:space:]]*(#|$)' "$patterns" || true)
[ -n "$values" ] || { echo "The patterns file has no values; nothing set." >&2; exit 1; }

for repo in "${repos[@]}"; do
  for app in actions dependabot; do
    printf '%s\n' "$values" | gh secret set PRIVATE_STRINGS --repo "$owner/$repo" --app "$app"
    echo "Set PRIVATE_STRINGS ($app) in $owner/$repo"
  done
done
echo "$(printf '%s\n' "$values" | wc -l | tr -d ' ') value(s) synced."
