#!/usr/bin/env bash
# Keeps one open pull request that upgrades Fleet (plan Task 39): fleet.Dockerfile set to
# the newest release, on a branch named for it (fleet-release-<version>), with Claude's
# review in its body. The daily release check runs it. To complete the upgrade, merge that
# pull request (docs/upgrading-fleet.md). A newer release gets a new pull request, and the
# older one is closed, so each pull request is one release.
#
#   release-pr.sh open  <version> <title> <body-file>   the version's pull request: new,
#                                                       or its body updated; then close
#                                                       any other release's
#   release-pr.sh close "<comment>"                     close every open one
#   release-pr.sh show  [version]                       print the open ones' bodies (only
#                                                       that version's, if given)
#
# open and close need GH_TOKEN from the release GitHub App (Contents and Pull requests
# write): a pull request opened with the workflow's own token wouldn't start the plan and
# lint checks. show only reads. Needs GITHUB_REPOSITORY. Only pull requests from this
# repository's own fleet-release-* branches count: anyone can open one from a fork's branch
# of the same name, and this must never touch theirs.
set -euo pipefail

mode="${1:?mode}"
repo="${GITHUB_REPOSITORY:?}"
semver='^[0-9]+\.[0-9]+\.[0-9]+$'

# "<number> <branch>" for each open release pull request.
open_prs() {
  gh pr list --repo "$repo" --state open --limit 100 --json number,headRefName,isCrossRepository \
    | jq -r '.[] | select((.isCrossRepository | not) and (.headRefName | test("^fleet-release-[0-9]+\\.[0-9]+\\.[0-9]+$")))
      | "\(.number) \(.headRefName)"'
}

case "$mode" in
  open)
    version="${2:?version}" title="${3:?title}" body="${4:?body file}"
    if [[ ! "$version" =~ $semver ]]; then
      echo "The version must look like 4.93.2 (got '$version')." >&2
      exit 2
    fi
    branch="fleet-release-$version"
    number=$(open_prs | awk -v b="$branch" '$2 == b { print $1 }')
    if [ -n "$number" ]; then
      gh pr edit "$number" --repo "$repo" --title "$title" --body-file "$body" > /dev/null
      echo "Updated pull request #$number."
    else
      # A fresh branch from main, replacing any left from an earlier pull request.
      main=$(gh api "repos/$repo/git/ref/heads/main" --jq .object.sha)
      if gh api "repos/$repo/git/ref/heads/$branch" > /dev/null 2>&1; then
        gh api -X PATCH "repos/$repo/git/refs/heads/$branch" -f sha="$main" -F force=true > /dev/null
      else
        gh api "repos/$repo/git/refs" -f ref="refs/heads/$branch" -f sha="$main" > /dev/null
      fi
      # Committed through the API, so the commit is the app's and signed by GitHub.
      file=$(gh api "repos/$repo/contents/fleet.Dockerfile?ref=$branch")
      old=$(jq -r .content <<< "$file" | base64 -d)
      new=$(sed -E "s|^FROM fleetdm/fleet:v[0-9]+\.[0-9]+\.[0-9]+$|FROM fleetdm/fleet:v$version|" <<< "$old")
      if [ "$new" = "$old" ]; then
        echo "fleet.Dockerfile on main is already on $version." >&2
        exit 1
      fi
      gh api -X PUT "repos/$repo/contents/fleet.Dockerfile" \
        -f message="Upgrade Fleet to $version" -f branch="$branch" \
        -f sha="$(jq -r .sha <<< "$file")" \
        -f content="$(printf '%s\n' "$new" | base64 -w0)" > /dev/null
      url=$(gh pr create --repo "$repo" --base main --head "$branch" --title "$title" --body-file "$body")
      echo "$url"
      number="${url##*/}"
    fi
    # Any other release's pull request is superseded.
    open_prs | while read -r other other_branch; do
      if [ "$other" != "$number" ]; then
        gh pr close "$other" --repo "$repo" --delete-branch \
          --comment "Superseded by #$number: Fleet $version is out." > /dev/null
        echo "Closed pull request #$other ($other_branch)."
      fi
    done
    ;;
  close)
    comment="${2:?comment}"
    open_prs | while read -r number branch; do
      gh pr close "$number" --repo "$repo" --comment "$comment" --delete-branch > /dev/null
      echo "Closed pull request #$number ($branch)."
    done
    ;;
  show)
    version="${2:-}"
    open_prs | while read -r number branch; do
      if [ -z "$version" ] || [ "$branch" = "fleet-release-$version" ]; then
        gh pr view "$number" --repo "$repo" --json body --jq .body
      fi
    done
    ;;
  *)
    echo "Unknown mode: $mode" >&2
    exit 2
    ;;
esac
