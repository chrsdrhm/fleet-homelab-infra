#!/usr/bin/env bash
# Sends one request to the Claude API, with no tools, and prints the response's JSON.
# Used by release-review.sh (Task 38) and health-review.sh (Task 30).
#
#   claude-message.sh <system-prompt-file> <message-file> [max-tokens]
#
# Signs in with workload identity federation, not an API key: the GitHub Actions identity
# token in ANTHROPIC_IDENTITY_TOKEN_FILE is exchanged for an Anthropic token that lasts
# minutes. Needs ANTHROPIC_ORGANIZATION_ID, ANTHROPIC_FEDERATION_RULE_ID and
# ANTHROPIC_SERVICE_ACCOUNT_ID (ANTHROPIC_WORKSPACE_ID only if the rule covers more than
# one workspace), and CLAUDE_REVIEW_MODEL (optional).
set -euo pipefail

system_file="${1:?system prompt file}" message_file="${2:?message file}" max_tokens="${3:-8000}"
model="${CLAUDE_REVIEW_MODEL:-claude-opus-5-5}"

jwt_file="${ANTHROPIC_IDENTITY_TOKEN_FILE:?ANTHROPIC_IDENTITY_TOKEN_FILE}"
exchange=$(jq -n --rawfile jwt "$jwt_file" \
  --arg rule "${ANTHROPIC_FEDERATION_RULE_ID:?}" \
  --arg org "${ANTHROPIC_ORGANIZATION_ID:?}" \
  --arg account "${ANTHROPIC_SERVICE_ACCOUNT_ID:?}" \
  --arg workspace "${ANTHROPIC_WORKSPACE_ID:-}" \
  '{grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: ($jwt | rtrimstr("\n")),
    federation_rule_id: $rule, organization_id: $org, service_account_id: $account}
   + (if $workspace == "" then {} else {workspace_id: $workspace} end)' \
  | curl -sS --fail-with-body https://api.anthropic.com/v1/oauth/token \
      -H "content-type: application/json" --data-binary @-) || {
  echo "The Anthropic token exchange failed (see the Console's Workload identity history)." >&2
  exit 1
}
token=$(jq -r '.access_token // empty' <<< "$exchange")
[ -n "$token" ] || { echo "The token exchange returned no access token." >&2; exit 1; }

response=$(jq -n --arg model "$model" --argjson max "$max_tokens" \
  --rawfile system "$system_file" --rawfile message "$message_file" \
  '{model: $model, max_tokens: $max, system: $system,
    messages: [{role: "user", content: $message}]}' \
  | curl -sS --fail-with-body --max-time 600 https://api.anthropic.com/v1/messages \
      -H "authorization: Bearer $token" \
      -H "anthropic-version: 2023-06-01" \
      -H "content-type: application/json" --data-binary @-) || {
  echo "The Claude API request failed: $(jq -r '.error.message // "no details"' <<< "$response" 2>/dev/null)" >&2
  exit 1
}
printf '%s\n' "$response"
