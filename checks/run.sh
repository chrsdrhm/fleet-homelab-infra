#!/usr/bin/env bash
# Runs every lint check and test, the same way in CI (the terraform-lint job) and on
# your machine. Runs all of them even if one fails, then prints a summary.
#
#   checks/run.sh            everything
#   checks/run.sh NAME...    only some: private-values fmt validate test shellcheck
#                            actionlint zizmor tflint
#
# Needs terraform, python3, shellcheck and git; actionlint and tflint from
# checks/install-tools.sh (put its folder on PATH); Docker for zizmor (skipped locally
# if Docker is not running; required in CI). The private-values check compares this
# branch with BASE (default: where it forked from origin/main); in CI, BASE, HEAD,
# TITLE and BODY come from the pull request.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
checks=checks
ZIZMOR_IMAGE=ghcr.io/zizmorcore/zizmor@sha256:a2eb396d886c053073405c7a980f2139ba2248ec172243cfa3841e57196e8101 # 1.30.1
export TFLINT_PLUGIN_DIR="${TFLINT_PLUGIN_DIR:-$PWD/.check-tools/tflint-plugins}"
if [ -d .check-tools ]; then PATH="$PWD/.check-tools:$PATH"; fi

failed=()
run() { # name, command...
  local name=$1; shift
  local tool="${TOOL:-$1}"
  if ! command -v "$tool" > /dev/null 2>&1 && ! declare -F "$tool" > /dev/null; then
    if [ -n "${CI:-}" ]; then echo "== $name: FAILED ($tool is not installed)"; failed+=("$name"); return; fi
    echo "== $name: skipped ($tool is not installed; CI runs it)"; return
  fi
  echo "::group::$name"
  if "$@"; then echo "== $name: ok"; else echo "== $name: FAILED"; failed+=("$name"); fi
  echo "::endgroup::"
}
selected=("$@")
want() { [ "${#selected[@]}" -eq 0 ] && return 0; local s; for s in "${selected[@]}"; do [ "$s" = "$1" ] && return 0; done; return 1; }

private_values() {
  python3 "$checks/tests/test_private_values.py" || return 1
  local base="${BASE:-}" head="${HEAD:-HEAD}" fail=0
  if [ -z "$base" ]; then
    base=$(git merge-base origin/main HEAD 2>/dev/null) || { echo "No origin/main to compare with; skipped the diff check."; return 0; }
  fi
  check() { python3 "$checks/private-values/check.py" "$1" || fail=1; }
  git diff --name-only "$base...$head" | check "the changed file names"
  while IFS= read -r f; do
    git diff -U0 "$base...$head" -- "$f" | grep '^+' | grep -v '^+++' | check "the added lines of $f"
  done < <(git diff --name-only --diff-filter=d "$base...$head")
  git log --format=%B "$base..$head" | check "the commit messages"
  if [ -n "${TITLE:-}${BODY:-}" ]; then
    printf '%s\n%s\n' "${TITLE:-}" "${BODY:-}" | check "the pull request title and body"
  fi
  [ "$fail" -eq 0 ] || echo "::error title=Private value found::Remove it from the pull request (and from the history of its commits)."
  return "$fail"
}

validate() {
  local dir
  for dir in . okta; do
    echo "-- $dir"
    terraform -chdir="$dir" init -input=false -backend=false > /dev/null && terraform -chdir="$dir" validate || return 1
  done
}

zizmor() {
  if ! docker info > /dev/null 2>&1; then
    if [ -n "${CI:-}" ]; then echo "Docker is not available."; return 1; fi
    echo "Docker is not running; zizmor skipped locally (CI runs it)."; return 0
  fi
  local token="${GH_TOKEN:-$(gh auth token 2>/dev/null || true)}" format=plain
  [ -n "${GITHUB_ACTIONS:-}" ] && format=github
  docker run --rm -v "$PWD:/repo:ro" -w /repo -e GH_TOKEN="$token" "$ZIZMOR_IMAGE" \
    --no-progress --format "$format" --config "$checks/zizmor.yml" .
}

tflint_all() {
  local dir
  tflint --init --config="$PWD/$checks/tflint.hcl" > /dev/null || return 1
  for dir in . okta; do
    echo "-- $dir"
    tflint --chdir="$dir" --config="$PWD/$checks/tflint.hcl" --format=compact || return 1
  done
}

want private-values && run private-values private_values
want fmt            && run fmt terraform fmt -check -recursive -diff
want validate       && run validate validate
want test           && run test terraform test -test-directory="$checks/tests/terraform"
want shellcheck     && run shellcheck shellcheck scripts/*.sh "$checks"/*.sh "$checks"/hooks/* "$checks"/private-values/*.sh
want actionlint     && run actionlint actionlint
want zizmor         && TOOL=docker run zizmor zizmor
want tflint         && TOOL=tflint run tflint tflint_all

if [ "${#failed[@]}" -gt 0 ]; then
  echo "Failed: ${failed[*]}"
  exit 1
fi
echo "All checks passed."
