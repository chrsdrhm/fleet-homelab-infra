#!/usr/bin/env bash
# Tears down the expensive part of the stack after snapshotting Aurora. Keeps Route 53,
# ACM, the state backend, secrets, the installers and logo buckets, SES and the budget.
# Unattended use (CI): CONFIRM=destroy. Snapshots kept: KEEP_SNAPSHOTS (default 2).
set -euo pipefail
cd "$(dirname "$0")/.."
export AWS_REGION="${AWS_REGION:-us-east-1}" AWS_PAGER=""
KEEP_SNAPSHOTS="${KEEP_SNAPSHOTS:-2}"

if [ ! -d .terraform ]; then
  echo "Terraform is not initialized here. Run: terraform init -backend-config=backend.hcl" >&2
  exit 1
fi

echo "This destroys the VPC (with the NAT Gateway), Aurora, Redis, the ALB, ECS, the WAF"
echo "Web ACL and the migrations runner, after snapshotting Aurora. Kept: Route 53, ACM,"
echo "the Terraform state, the secrets, the S3 buckets, SES and the budget."
if [ "${CONFIRM:-}" != "destroy" ]; then
  if [ -t 0 ]; then
    read -r -p "Type 'destroy' to confirm: " CONFIRM || CONFIRM=""
  else
    echo "Not confirmed: set CONFIRM=destroy to run this without a terminal (in CI, the 'confirm' input)." >&2
    exit 1
  fi
fi
if [ "$CONFIRM" != "destroy" ]; then echo "Aborted: nothing was changed." >&2; exit 1; fi

if aws rds describe-db-clusters --db-cluster-identifier fleet-homelab >/dev/null 2>&1; then
  SNAPSHOT_ID="fleet-homelab-teardown-$(date -u +%Y%m%d%H%M%S)"
  echo "Snapshotting Aurora as $SNAPSHOT_ID..."
  aws rds create-db-cluster-snapshot --db-cluster-identifier fleet-homelab \
    --db-cluster-snapshot-identifier "$SNAPSHOT_ID" \
    --tags Key=Project,Value=fleet-lab Key=ManagedBy,Value=script >/dev/null
  aws rds wait db-cluster-snapshot-available --db-cluster-snapshot-identifier "$SNAPSHOT_ID"
  echo "Snapshot available: $SNAPSHOT_ID"
else
  SNAPSHOT_ID=""
  echo "No Aurora cluster found: nothing to snapshot (the stack may already be down)."
fi

terraform destroy -input=false -auto-approve -var-file=terraform.tfvars \
  -target=aws_route53_record.fleet_alb \
  -target=aws_cloudwatch_log_group.container_insights \
  -target=module.migrations \
  -target=aws_wafv2_web_acl_association.fleet_homelab \
  -target=aws_wafv2_web_acl.fleet_homelab \
  -target=module.fleet

# ECS Container Insights keeps writing while the cluster shuts down, so AWS re-creates
# this log group (untagged) right after Terraform deletes it. Left behind, it makes the
# next up.sh fail with ResourceAlreadyExistsException. Delete it, then once more.
LG=/aws/ecs/containerinsights/fleet-homelab/performance
aws logs delete-log-group --log-group-name "$LG" 2>/dev/null || true
sleep 20
aws logs delete-log-group --log-group-name "$LG" 2>/dev/null || true

# Keep the newest KEEP_SNAPSHOTS teardown snapshots; each one bills while it exists.
# Only runs when this run took a snapshot, so a restore point always survives.
if [ -n "$SNAPSHOT_ID" ]; then
  OLD=$(aws rds describe-db-cluster-snapshots --snapshot-type manual \
    --query "sort_by(DBClusterSnapshots[?starts_with(DBClusterSnapshotIdentifier, 'fleet-homelab-teardown-')], &SnapshotCreateTime)[].DBClusterSnapshotIdentifier" \
    --output text | tr '\t' '\n' | awk -v k="$KEEP_SNAPSHOTS" 'NF{a[n++]=$0} END{for(i=0;i<n-k;i++) print a[i]}')
  for s in $OLD; do
    [ "$s" = "$SNAPSHOT_ID" ] && continue
    echo "Pruning old snapshot: $s"
    aws rds delete-db-cluster-snapshot --db-cluster-snapshot-identifier "$s" >/dev/null
  done
fi

# Verify nothing billable from the stack is left.
LEFT=0
check() { if [ "$2" != "0" ]; then echo "STILL PRESENT: $1 ($2)"; LEFT=1; fi; }
check "ECS cluster"   "$(aws ecs describe-clusters --clusters fleet-homelab --query "length(clusters[?status=='ACTIVE'])" --output text)"
check "Aurora"        "$(aws rds describe-db-clusters --query 'length(DBClusters)' --output text)"
check "Redis"         "$(aws elasticache describe-replication-groups --query 'length(ReplicationGroups)' --output text)"
check "load balancer" "$(aws elbv2 describe-load-balancers --query 'length(LoadBalancers)' --output text)"
check "NAT gateway"   "$(aws ec2 describe-nat-gateways --filter Name=state,Values=pending,available --query 'length(NatGateways)' --output text)"
check "VPC"           "$(aws ec2 describe-vpcs --filters Name=tag:Project,Values=fleet-lab --query 'length(Vpcs)' --output text)"
check "WAF web ACL"   "$(aws wafv2 list-web-acls --scope REGIONAL --query 'length(WebACLs)' --output text)"
if [ "$LEFT" -ne 0 ]; then echo "Down, but something is still present (see above)." >&2; exit 2; fi
echo "Down and verified: nothing billable from the stack remains.${SNAPSHOT_ID:+ Restore point: $SNAPSHOT_ID}"
