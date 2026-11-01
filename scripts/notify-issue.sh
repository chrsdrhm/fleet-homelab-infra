#!/usr/bin/env bash
# Keeps one open GitHub issue per title, for notices from scheduled runs (the nightly
# teardown, kept snapshots, the health scan). GitHub notifies the repository's owner of new issues and
# comments, by email and in its mobile app.
#
#   notify-issue.sh report  "<title>" <body-file>   new issue, or a comment on the open one
#   notify-issue.sh update  "<title>" <body-file>   new issue, or quietly replace the open
#                                                   one's body if it changed
#   notify-issue.sh resolve "<title>" "<comment>"   close the open one, if any
#   notify-issue.sh show    "<title>"               print the open one's body, if any
#
# Needs GH_TOKEN with issues: write and GITHUB_REPOSITORY. Never put identifying values in
# a body: issues are public. Only issues opened by NOTIFY_AUTHOR (the workflow's own
# GitHub Actions bot, as `gh` names it) count: in a public repo anyone can open an issue
# with the same title, and this must never comment on, rewrite or close theirs.
set -euo pipefail

mode="${1:?mode}" title="${2:?title}"
if [ "$mode" != show ]; then
  arg="${3:?body file or comment}"
fi
repo="${GITHUB_REPOSITORY:?}"
author="${NOTIFY_AUTHOR:-app/github-actions}"

# The open issue with exactly this title, opened by $author, if any. Listed, not searched:
# GitHub's search index lags, so a search can miss an issue opened moments ago, or find
# one just closed.
number=$(gh issue list --repo "$repo" --state open --limit 200 --json number,title,author \
  | jq -r --arg t "$title" --arg a "$author" \
    'map(select(.title == $t and .author.login == $a)) | first | .number // empty')

case "$mode" in
  report)
    if [ -n "$number" ]; then
      gh issue comment "$number" --repo "$repo" --body-file "$arg" > /dev/null
      echo "Commented on issue #$number."
    else
      gh issue create --repo "$repo" --title "$title" --body-file "$arg"
    fi
    ;;
  update)
    if [ -z "$number" ]; then
      gh issue create --repo "$repo" --title "$title" --body-file "$arg"
    elif [ "$(gh issue view "$number" --repo "$repo" --json body --jq .body)" != "$(cat "$arg")" ]; then
      gh issue edit "$number" --repo "$repo" --body-file "$arg" > /dev/null
      echo "Updated issue #$number."
    else
      echo "Issue #$number is current."
    fi
    ;;
  resolve)
    if [ -n "$number" ]; then
      gh issue close "$number" --repo "$repo" --comment "$arg" > /dev/null
      echo "Closed issue #$number."
    fi
    ;;
  show)
    if [ -n "$number" ]; then
      gh issue view "$number" --repo "$repo" --json body --jq .body
    fi
    ;;
  *)
    echo "Unknown mode: $mode" >&2
    exit 2
    ;;
esac
