#!/usr/bin/env bash
# After a rebuild: when Fleet reports SSO on, starting a login must return a SAML request
# for the identity provider. Prints the result; never prints the redirect URL (it holds
# the IdP org). Exit 1 if SSO is on but broken, 0 otherwise (off counts as fine).
# FLEET_CI_HEADER, if set, is sent as x-fleet-ci (gets CI runners past the WAF).
# Usage: checks/sso-smoke.sh FLEET_URL
set -euo pipefail
url="${1:?usage: sso-smoke.sh FLEET_URL}"
hdr=()
[ -n "${FLEET_CI_HEADER:-}" ] && hdr=(-H "x-fleet-ci: $FLEET_CI_HEADER")
command -v jq >/dev/null || { echo "SSO: check skipped (jq not installed)."; exit 0; }

on=$(curl -s -m 20 ${hdr[@]+"${hdr[@]}"} "$url/api/v1/fleet/sso" | jq -r '.settings.sso_enabled // false' 2>/dev/null || echo false)
if [ "$on" != "true" ]; then
  echo "SSO: off; check skipped."
elif curl -s -m 20 ${hdr[@]+"${hdr[@]}"} -X POST -H 'Content-Type: application/json' -d '{"relay_url":"/"}' \
    "$url/api/v1/fleet/sso" | jq -e '(.url // "") | test("SAMLRequest=")' >/dev/null 2>&1; then
  echo "SSO: starting a login redirects to the identity provider."
else
  echo "SSO is on, but starting a login did not redirect to the identity provider. Check Fleet's SSO settings and the IdP's metadata URL." >&2
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::warning title=SSO check failed::SSO is on, but starting a login did not redirect to the identity provider."
  fi
  exit 1
fi
