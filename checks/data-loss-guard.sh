#!/usr/bin/env bash
# Lists the resources a saved plan would destroy or replace that hold data or identity:
# the database, the server key that decrypts it, secrets, buckets, the DNS zone, the
# certificate and the email identity. One "address (destroy|replace)" per line; empty
# output means nothing at risk. Matched by type, so it keeps working if Fleet's module
# renames things. for_each keys are hidden (they can contain the hostname).
# Usage: checks/data-loss-guard.sh PLANFILE   (run where `terraform show` works)
set -euo pipefail
plan="${1:?usage: data-loss-guard.sh PLANFILE}"
terraform show -json "$plan" | jq -r '.resource_changes[]?
  | select(.change.actions | index("delete"))
  | select((.type | IN("aws_rds_cluster", "aws_secretsmanager_secret", "aws_s3_bucket",
      "aws_route53_zone", "aws_acm_certificate", "aws_ses_domain_identity"))
    or .address == "random_password.fleet_server_private_key")
  | "\(.address) (\(if (.change.actions | index("create")) then "replace" else "destroy" end))"' \
  | sed -E 's/\["[^"]*"\]/["…"]/g'
