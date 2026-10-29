#!/usr/bin/env bash
# Read-only health scan of the running stack (plan Task 21's twelve checks, Task 30).
# Prints a Markdown report of raw figures; the /health-scan skill compares it with the
# baseline in .claude/skills/health-scan/baseline.md. Changes nothing.
#
#   health-scan.sh [hours]     the window to look back over (default 72, Task 21's)
#
# Fleet's URL comes from `terraform output -raw fleet_url`, or FLEET_URL if set.
# FLEET_CI_HEADER (CI only) gets past the WAF's US-only rule. FLEET_API_TOKEN, if set,
# adds Fleet's status endpoints; without it they're skipped.
#
# The report is safe to post publicly: the Fleet hostname and domain, account IDs, ARNs
# email addresses and IP addresses are masked, and only counts and figures are printed.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
export AWS_REGION="${AWS_REGION:-us-east-1}" AWS_PAGER=""

hours="${1:-72}"
if [[ ! "$hours" =~ ^[0-9]+$ ]] || [ "$hours" -lt 1 ]; then
  echo "hours must be a whole number, 1 or more" >&2
  exit 2
fi
now=$(date -u +%s)
start=$((now - hours * 3600))
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
start_iso=$(iso "$start") end_iso=$(iso "$now")
period=$(( (hours * 3600 + 59) / 60 * 60 ))

url="${FLEET_URL:-$(terraform output -raw fleet_url 2>/dev/null || true)}"
host="${url#https://}" host="${host%%/*}"
domain="${host#*.}"
account=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)

# Everything printed goes through mask.
mask() {
  local s
  s=$(sed -E 's#arn:aws[a-zA-Z-]*:[^ ,")]*#<arn>#g; s/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g
    s/[0-9]{1,3}(\.[0-9]{1,3}){3}/<ip>/g')
  [ -n "$host" ] && s=${s//"$host"/<fleet-host>}
  [ -n "$domain" ] && [ "$domain" != "$host" ] && s=${s//"$domain"/<domain>}
  [ -n "$account" ] && s=${s//"$account"/<account>}
  printf '%s\n' "$s"
}
section() { printf '\n## %s\n\n' "$1"; }
fail() { echo "- (couldn't read: $1)"; }
bullets() { sed 's/^/  - /'; }

# One CloudWatch statistic over the whole window: metric <namespace> <name> <stat>
# <dimensions...>. Sum adds the datapoints, Maximum and Minimum take the extreme,
# Average averages them. Prints "none" when there's no data.
metric() {
  local ns="$1" name="$2" stat="$3"; shift 3
  aws cloudwatch get-metric-statistics --namespace "$ns" --metric-name "$name" \
    --start-time "$start_iso" --end-time "$end_iso" --period "$period" --statistics "$stat" \
    --dimensions "$@" --query "Datapoints[].$stat" --output json 2>/dev/null \
    | jq -r --arg stat "$stat" 'if length == 0 then "none"
        elif $stat == "Sum" then add
        elif $stat == "Maximum" then max
        elif $stat == "Minimum" then min
        else add / length end
        | if type == "number" then (. * 100 | round / 100) else . end' 2>/dev/null || echo "error"
}

echo "# Health scan"
echo
echo "Window: the last $hours hours ($start_iso to $end_iso)."

# 1. ECS
section "1. ECS service"
if svc=$(aws ecs describe-services --cluster fleet-homelab --services fleet --output json 2>/dev/null); then
  jq -r '.services[0] | "- Running \(.runningCount) of \(.desiredCount) desired; rollout \(.deployments[0].rolloutState // "unknown"); \(.deployments | length) deployment(s)"' <<< "$svc"
  echo "- Recent events:"
  jq -r '.services[0].events[:5][] | "  - \(.createdAt) \(.message)"' <<< "$svc" | mask
  stopped=$(aws ecs list-tasks --cluster fleet-homelab --desired-status STOPPED --query 'taskArns' --output json 2>/dev/null || echo '[]')
  echo "- Stopped tasks still listed (ECS keeps them about an hour): $(jq length <<< "$stopped")"
  if [ "$(jq length <<< "$stopped")" -gt 0 ]; then
    # shellcheck disable=SC2046 # one argument per task ARN
    aws ecs describe-tasks --cluster fleet-homelab --tasks $(jq -r '.[:10][]' <<< "$stopped") \
      --query 'tasks[].[stoppedReason, containers[0].exitCode]' --output text 2>/dev/null \
      | sort | uniq -c | sed 's/^/  - /' | mask
  fi
else
  fail "ECS"
fi

# 2. Fleet's app logs
section "2. Fleet app logs"
group=$(aws logs describe-log-groups --log-group-name-prefix terraform- --query 'logGroups[0].logGroupName' --output text 2>/dev/null)
insights() {
  local id status
  id=$(aws logs start-query --log-group-name "$group" --start-time "$start" --end-time "$now" \
    --query-string "$1" --query queryId --output text 2>/dev/null) || return 1
  for _ in $(seq 1 30); do
    sleep 2
    status=$(aws logs get-query-results --query-id "$id" --output json 2>/dev/null) || return 1
    case $(jq -r .status <<< "$status") in
      Complete) jq -r '.results[] | map(.value) | join(" | ")' <<< "$status"; return 0 ;;
      Failed|Cancelled|Timeout) return 1 ;;
    esac
  done
  return 1
}
if [ -z "$group" ] || [ "$group" = None ]; then
  fail "no Fleet log group (is the stack up?)"
else
  # Each query's result is captured first, so a failed query reads "couldn't read",
  # never as no errors.
  echo "- Records by level (level | count; a blank level is a line that isn't Fleet's JSON):"
  if r=$(insights 'stats count(*) as n by level | sort n desc'); then
    bullets <<< "$r" | mask
  else
    fail "Logs Insights"
  fi
  echo "- Top errors and warnings (level | message | count; none if empty):"
  if r=$(insights 'filter level in ["error","warn"] | stats count(*) as n by level, msg | sort n desc | limit 15'); then
    [ -n "$r" ] && bullets <<< "$r" | mask
  else
    fail "Logs Insights"
  fi
  echo "- Keyword hits (count):"
  for word in panic fatal "out of memory" "connection refused" deadlock "too many connections" "context deadline" timeout; do
    if r=$(insights "filter @message like /(?i)$word/ | stats count(*)"); then
      echo "  - $word: $(head -n 1 <<< "$r" | grep . || echo 0)"
    else
      echo "  - $word: (couldn't read)"
    fi
  done
fi

# 3. Load balancer
section "3. Load balancer"
if lb=$(aws elbv2 describe-load-balancers --names fleet-homelab --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null); then
  lbdim="Name=LoadBalancer,Value=${lb#*:loadbalancer/}"
  tg=$(aws elbv2 describe-target-groups --names fleet-homelab --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)
  echo "- Targets by state: $(aws elbv2 describe-target-health --target-group-arn "$tg" --query 'TargetHealthDescriptions[].TargetHealth.State' --output text 2>/dev/null | tr '\t' '\n' | sort | uniq -c | xargs)"
  for m in RequestCount HTTPCode_Target_2XX_Count HTTPCode_Target_4XX_Count HTTPCode_Target_5XX_Count HTTPCode_ELB_5XX_Count; do
    echo "- $m (sum): $(metric AWS/ApplicationELB "$m" Sum "$lbdim")"
  done
  echo "- TargetResponseTime, seconds: average $(metric AWS/ApplicationELB TargetResponseTime Average "$lbdim"), maximum $(metric AWS/ApplicationELB TargetResponseTime Maximum "$lbdim")"
else
  fail "the load balancer"
fi

# 4. Aurora
section "4. Aurora"
db="Name=DBInstanceIdentifier,Value=fleet-homelab-one"
if j=$(aws rds describe-db-clusters --db-cluster-identifier fleet-homelab --output json 2>/dev/null); then
  jq -r '.DBClusters[0] | "- Status: \(.Status); engine \(.EngineVersion)"' <<< "$j"
else
  fail "the cluster"
fi
echo "- Events (instance and cluster):"
for type in db-instance db-cluster; do
  id=fleet-homelab; [ "$type" = db-instance ] && id=fleet-homelab-one
  if r=$(aws rds describe-events --source-type "$type" --source-identifier "$id" --start-time "$start_iso" \
    --query 'Events[].[Date, Message]' --output text 2>/dev/null); then
    [ -n "$r" ] && cut -c1-200 <<< "$r" | sed 's/^/  - /' | mask
  else
    fail "$type events"
  fi
done
echo "- Pending maintenance actions: $(aws rds describe-pending-maintenance-actions --query 'length(PendingMaintenanceActions)' --output text 2>/dev/null || echo error)"
echo "- CPU %: average $(metric AWS/RDS CPUUtilization Average "$db"), maximum $(metric AWS/RDS CPUUtilization Maximum "$db")"
echo "- CPUCreditBalance: minimum $(metric AWS/RDS CPUCreditBalance Minimum "$db"), maximum $(metric AWS/RDS CPUCreditBalance Maximum "$db"); CPUSurplusCreditsCharged (sum): $(metric AWS/RDS CPUSurplusCreditsCharged Sum "$db")"
echo "- FreeableMemory, minimum bytes: $(metric AWS/RDS FreeableMemory Minimum "$db")"
echo "- DatabaseConnections, maximum: $(metric AWS/RDS DatabaseConnections Maximum "$db")"

# 5. Fargate
section "5. Fargate task"
ecsdims=("Name=ClusterName,Value=fleet-homelab" "Name=ServiceName,Value=fleet")
echo "- CPU %: average $(metric AWS/ECS CPUUtilization Average "${ecsdims[@]}"), maximum $(metric AWS/ECS CPUUtilization Maximum "${ecsdims[@]}")"
echo "- Memory %: average $(metric AWS/ECS MemoryUtilization Average "${ecsdims[@]}"), maximum $(metric AWS/ECS MemoryUtilization Maximum "${ecsdims[@]}")"

# 6. Redis
section "6. Redis"
redis="Name=CacheClusterId,Value=fleet-homelab-001"
echo "- Events:"
if r=$(aws elasticache describe-events --source-type cache-cluster --source-identifier fleet-homelab-001 --start-time "$start_iso" \
  --query 'Events[].[Date, Message]' --output text 2>/dev/null); then
  [ -n "$r" ] && cut -c1-200 <<< "$r" | sed 's/^/  - /' | mask
else
  fail "Redis events"
fi
echo "- EngineCPUUtilization %: average $(metric AWS/ElastiCache EngineCPUUtilization Average "$redis"), maximum $(metric AWS/ElastiCache EngineCPUUtilization Maximum "$redis")"
echo "- Evictions (sum): $(metric AWS/ElastiCache Evictions Sum "$redis")"

# 7. WAF
section "7. WAF"
waf=("Name=WebACL,Value=fleet-homelab" "Name=Region,Value=$AWS_REGION" "Name=Rule,Value=ALL")
echo "- AllowedRequests (sum): $(metric AWS/WAFV2 AllowedRequests Sum "${waf[@]}")"
echo "- BlockedRequests (sum): $(metric AWS/WAFV2 BlockedRequests Sum "${waf[@]}")"

# 8. SES
section "8. SES"
if j=$(aws sesv2 get-account --output json 2>/dev/null); then
  jq -r '"- Sending enabled: \(.SendingEnabled); enforcement \(.EnforcementStatus); production access (out of the sandbox): \(.ProductionAccessEnabled)"' <<< "$j"
else
  fail "SES"
fi
if j=$(aws ses get-send-statistics --output json 2>/dev/null); then
  jq -r --arg start "$start_iso" '[.SendDataPoints[] | select(.Timestamp >= $start)]
      | "- In the window: \(map(.DeliveryAttempts) | add // 0) sent, \(map(.Bounces) | add // 0) bounces, \(map(.Complaints) | add // 0) complaints, \(map(.Rejects) | add // 0) rejects"' <<< "$j"
else
  fail "SES statistics"
fi

# 9. Certificate and DNS
section "9. Certificate and DNS"
cert=$(aws acm list-certificates --query 'CertificateSummaryList[0].CertificateArn' --output text 2>/dev/null)
if [ -n "$cert" ] && [ "$cert" != None ]; then
  if j=$(aws acm describe-certificate --certificate-arn "$cert" --output json 2>/dev/null); then
    jq -r '.Certificate | "- Certificate: \(.Status); expires \(.NotAfter); renewal \(.RenewalEligibility)"' <<< "$j"
  else
    fail "the certificate"
  fi
else
  fail "the certificate"
fi
if [ -n "$host" ]; then
  echo "- Fleet host resolves to $(dig +short "$host" A 2>/dev/null | grep -c .) address(es); its zone has $(dig +short "$domain" NS 2>/dev/null | grep -c .) name server(s)"
else
  fail "Fleet's URL (no terraform output and no FLEET_URL)"
fi

# 10. Budget
section "10. Budget"
if [ -n "$account" ]; then
  if j=$(aws budgets describe-budget --account-id "$account" --budget-name fleet-homelab-monthly --output json 2>/dev/null); then
    jq -r '.Budget | "- This month: $\(.CalculatedSpend.ActualSpend.Amount | tonumber | . * 100 | round / 100) actual, $\(.CalculatedSpend.ForecastedSpend.Amount // "0" | tonumber | . * 100 | round / 100) forecast, of a $\(.BudgetLimit.Amount | tonumber | round) limit"' <<< "$j"
  else
    fail "the budget"
  fi
else
  fail "the account"
fi

# 11. Fleet itself, and GitHub
section "11. Fleet and GitHub"
hdr=()
[ -n "${FLEET_CI_HEADER:-}" ] && hdr=(-H "x-fleet-ci: $FLEET_CI_HEADER")
if [ -n "$url" ]; then
  echo "- /healthz: HTTP $(curl -s -o /dev/null -m 20 -w '%{http_code}' ${hdr[@]+"${hdr[@]}"} "$url/healthz")"
  if [ -n "${FLEET_API_TOKEN:-}" ]; then
    for path in result_store live_query; do
      body=$(curl -s -m 20 ${hdr[@]+"${hdr[@]}"} -H "Authorization: Bearer $FLEET_API_TOKEN" -w '\n%{http_code}' "$url/api/v1/fleet/status/$path")
      echo "- /status/$path: HTTP $(tail -n 1 <<< "$body"), body $(sed '$d' <<< "$body" | tr -d '\n' | cut -c1-120)" | mask
    done
  else
    echo "- Status endpoints: skipped (no FLEET_API_TOKEN)"
  fi
fi
owner=$(gh repo view --json owner --jq .owner.login 2>/dev/null || true)
if [ -n "$owner" ]; then
  gh run list --repo "$owner/fleet-homelab-gitops" --workflow workflow.yml --limit 1 \
    --json conclusion,event,createdAt --jq '.[] | "- Latest GitOps run: \(.conclusion) (\(.event), \(.createdAt))"' 2>/dev/null || fail "GitOps runs"
  for repo in fleet-homelab-infra fleet-homelab-gitops; do
    d=$(gh api "repos/$owner/$repo/dependabot/alerts?state=open" --jq length 2>/dev/null || echo "n/a")
    s=$(gh api "repos/$owner/$repo/secret-scanning/alerts?state=open" --jq length 2>/dev/null || echo "n/a")
    echo "- $repo: $d open Dependabot alerts, $s open secret-scanning alerts"
  done
fi

# 12. Not covered
section "12. Not covered here"
echo "- Okta's System Log, CloudTrail, Cloudflare and Fleet's activity feed: check them in their own consoles."
