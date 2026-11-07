#!/usr/bin/env bash
# Prints Fleet's server releases as X.Y.Z, one per line, drafts and prereleases left out.
# The repo also publishes agent releases, so only fleet-vX.Y.Z tags count. Used by the
# daily release check (fleet-checks.yml) and scripts/release-review.sh. Needs GH_TOKEN.
#
#   fleet-releases.sh [<oldest>]
#
# Without <oldest>, reads the newest 100 releases. With it, reads on until a page reaches
# a release at or below <oldest>, and fails if five pages (about two years of releases)
# don't get there, rather than return a partial list.
#
# Reads GraphQL, not the REST releases list: the REST list has left out a new release for
# more than a day while /releases/latest and GraphQL had it, so the check missed it.
set -euo pipefail

oldest="${1:-}"
newer() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]; }

# $cursor is a GraphQL variable, not a shell one.
# shellcheck disable=SC2016
query='query($cursor: String) {
  repository(owner: "fleetdm", name: "fleet") {
    releases(first: 100, after: $cursor, orderBy: {field: CREATED_AT, direction: DESC}) {
      pageInfo { hasNextPage endCursor }
      nodes { tagName isDraft isPrerelease }
    }
  }
}'

cursor=""
reached=false
for _ in 1 2 3 4 5; do
  args=(-f query="$query")
  if [ -n "$cursor" ]; then
    args+=(-f cursor="$cursor")
  fi
  page=$(gh api graphql "${args[@]}")
  versions=$(jq -r '.data.repository.releases.nodes[]
    | select((.isDraft or .isPrerelease) | not) | .tagName
    | select(test("^fleet-v[0-9]+\\.[0-9]+\\.[0-9]+$")) | ltrimstr("fleet-v")' <<< "$page")
  if [ -n "$versions" ]; then
    echo "$versions"
  fi
  if [ -z "$oldest" ] || [ "$(jq -r .data.repository.releases.pageInfo.hasNextPage <<< "$page")" != true ]; then
    reached=true
    break
  fi
  if [ -n "$versions" ] && ! newer "$(sort -V <<< "$versions" | head -n 1)" "$oldest"; then
    reached=true
    break
  fi
  cursor=$(jq -r .data.repository.releases.pageInfo.endCursor <<< "$page")
done
if [ "$reached" != true ]; then
  echo "Five pages of Fleet's releases didn't reach $oldest; the list would be incomplete." >&2
  exit 1
fi
