#!/usr/bin/env bash
# Fails if standard input contains any string from PATTERNS_FILE (one per line, matched
# literally and case-insensitively; blank lines and # comments ignored). Reports only
# which input lines matched, never the text, so it is safe in public CI logs.
# Used by the lint job (patterns from the PRIVATE_STRINGS secret) and by the optional
# hooks in .githooks/ (patterns from a file outside the repo).
# Usage: check-private-strings.sh PATTERNS_FILE LABEL < text
set -euo pipefail
patterns="${1:?usage: check-private-strings.sh PATTERNS_FILE LABEL < text}"
label="${2:-input}"

clean=$(mktemp)
trap 'rm -f "$clean"' EXIT
grep -v -E '^[[:space:]]*(#|$)' "$patterns" > "$clean" || true
if [ ! -s "$clean" ]; then
  cat > /dev/null
  exit 0
fi

lines=$(grep -n -i -F -f "$clean" | cut -d: -f1 | paste -sd, - || true)
if [ -n "$lines" ]; then
  echo "Private string found in $label (line ${lines})." >&2
  exit 1
fi
