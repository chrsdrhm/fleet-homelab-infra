#!/usr/bin/env bash
# Makes untrusted text safe to post in a public issue, pull request or run summary
# (Claude's reviews of release notes and of health-scan logs: release-review.sh,
# health-review.sh). Reads stdin, writes stdout. Each break is a zero-width space, so the
# text, code included, still reads the same once rendered, but none of it is live:
#  - @mentions: "@" + space, so nobody is notified
#  - every "<": no HTML tag or comment can form (so nothing hidden, and no fake
#    "release-review" marker, which would skip a later review)
#  - "]" before "(", "[" or ":": no link, image, reference link or link definition
#  - "//" and "www.": no bare URL autolink
# checks/tests/test_sanitize_markdown.py feeds it hostile input; change both together.
set -euo pipefail

z=$(printf '\342\200\213') # U+200B, zero-width space
# Byte-wise (LC_ALL=C), so macOS sed and GNU sed treat the multibyte space the same.
LC_ALL=C sed -E \
  -e "s/@([A-Za-z0-9])/@$z\\1/g" \
  -e "s/</<$z/g" \
  -e "s/\\]([[(:])/]$z\\1/g" \
  -e "s#//#/$z/#g" \
  -e "s/www\\./www$z./g"
