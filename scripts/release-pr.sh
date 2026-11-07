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
#   release-pr.sh declined <version>                    print the number of that version's
#                                                       pull request if it was closed
#                                                       without merging (declined)
#
# Closing a pull request deletes its branch, unless someone other than a bot pushed to it:
# then the branch is kept, so that work isn't lost.
#
# open and close need GH_TOKEN from the release GitHub App (Contents and Pull requests
# write): a pull request opened with the workflow's own token wouldn't start the plan and
# lint checks. show and declined only read. Needs GITHUB_REPOSITORY. Only pull requests from this
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

# Closes a release pull request with a comment. Its branch is deleted only if every commit
# on it (merges from main aside) is a bot's: the app's version change, never a person's.
close_pr() {
  local number="$1" branch="$2" comment="$3" people
  people=$(gh api "repos/$repo/compare/main...$branch" \
    --jq '[.commits[] | select((.parents | length) == 1) | .author.login // "" | select(endswith("[bot]") | not)] | length')
  if [ "$people" = 0 ]; then
    gh pr close "$number" --repo "$repo" --comment "$comment" --delete-branch > /dev/null
  else
    gh pr close "$number" --repo "$repo" --comment "$comment Its branch, \`$branch\`, is kept: it has commits beyond the version change." > /dev/null
  fi
  echo "Closed pull request #$number ($branch)."
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
        close_pr "$other" "$other_branch" "Superseded by #$number: Fleet $version is out."
      fi
    done
    ;;
  close)
    comment="${2:?comment}"
    open_prs | while read -r number branch; do
      close_pr "$number" "$branch" "$comment"
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
  declined)
    version="${2:?version}"
    gh pr list --repo "$repo" --state closed --head "fleet-release-$version" --limit 20 \
      --json number,mergedAt,isCrossRepository \
      --jq '[.[] | select((.isCrossRepository | not) and .mergedAt == null)] | first | .number // empty'
    ;;
  *)
    echo "Unknown mode: $mode" >&2
    exit 2
    ;;
esac
