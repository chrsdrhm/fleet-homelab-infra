#!/usr/bin/env bash
# Keeps one open pull request that upgrades Fleet (plan Task 39): fleet.Dockerfile set to
# the newest release, on the fleet-release branch, with Claude's review in its body. The
# daily release check runs it. Merging it is the upgrade (docs/upgrading-fleet.md).
#
#   release-pr.sh open  <version> <title> <body-file>   new pull request, or update the
#                                                       open one (its branch keeps any
#                                                       commits pushed to it)
#   release-pr.sh close "<comment>"                     close the open one, if any
#   release-pr.sh show                                  print the open one's body, if any
#
# open and close need GH_TOKEN from the release GitHub App (Contents and Pull requests
# write): a pull request opened with the workflow's own token wouldn't start the plan and
# lint checks. show only reads. Needs GITHUB_REPOSITORY. Only a pull request from this
# repository's own fleet-release branch counts: anyone can open one from a fork's branch
# of the same name, and this must never touch theirs.
set -euo pipefail

mode="${1:?mode}"
repo="${GITHUB_REPOSITORY:?}"
branch=fleet-release

number=$(gh pr list --repo "$repo" --head "$branch" --state open --json number,isCrossRepository \
  | jq -r 'map(select(.isCrossRepository | not)) | first | .number // empty')

case "$mode" in
  open)
    version="${2:?version}" title="${3:?title}" body="${4:?body file}"
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "The version must look like 4.93.2 (got '$version')." >&2
      exit 2
    fi
    if [ -z "$number" ]; then
      # A fresh branch from main, replacing any left from an earlier pull request.
      main=$(gh api "repos/$repo/git/ref/heads/main" --jq .object.sha)
      if gh api "repos/$repo/git/ref/heads/$branch" > /dev/null 2>&1; then
        gh api -X PATCH "repos/$repo/git/refs/heads/$branch" -f sha="$main" -F force=true > /dev/null
      else
        gh api "repos/$repo/git/refs" -f ref="refs/heads/$branch" -f sha="$main" > /dev/null
      fi
    fi
    # Committed through the API, so the commit is the app's and signed by GitHub.
    file=$(gh api "repos/$repo/contents/fleet.Dockerfile?ref=$branch")
    old=$(jq -r .content <<< "$file" | base64 -d)
    new=$(sed -E "s|^FROM fleetdm/fleet:v[0-9]+\.[0-9]+\.[0-9]+$|FROM fleetdm/fleet:v$version|" <<< "$old")
    if [ "$new" = "$old" ]; then
      echo "fleet.Dockerfile on $branch is already on $version."
    else
      gh api -X PUT "repos/$repo/contents/fleet.Dockerfile" \
        -f message="Upgrade Fleet to $version" -f branch="$branch" \
        -f sha="$(jq -r .sha <<< "$file")" \
        -f content="$(printf '%s\n' "$new" | base64 -w0)" > /dev/null
      echo "Set fleet.Dockerfile on $branch to $version."
    fi
    if [ -n "$number" ]; then
      gh pr edit "$number" --repo "$repo" --title "$title" --body-file "$body" > /dev/null
      echo "Updated pull request #$number."
    else
      gh pr create --repo "$repo" --base main --head "$branch" --title "$title" --body-file "$body"
    fi
    ;;
  close)
    comment="${2:?comment}"
    if [ -n "$number" ]; then
      gh pr close "$number" --repo "$repo" --comment "$comment" --delete-branch > /dev/null
      echo "Closed pull request #$number."
    fi
    ;;
  show)
    if [ -n "$number" ]; then
      gh pr view "$number" --repo "$repo" --json body --jq .body
    fi
    ;;
  *)
    echo "Unknown mode: $mode" >&2
    exit 2
    ;;
esac
