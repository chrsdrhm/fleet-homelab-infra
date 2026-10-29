---
name: health-scan
description: Read-only health scan of the running stack - ECS, Fleet's logs, the load balancer, Aurora, Redis, WAF, SES, the certificate, DNS, the budget and GitHub - compared with the baseline, reporting only what's new. Run it when the person asks, after an upgrade, or before a teardown.
allowed-tools: Bash(scripts/health-scan.sh), Bash(scripts/health-scan.sh *), Bash(aws rds describe-db-clusters --db-cluster-identifier fleet-homelab --query *), Bash(aws ecs describe-services --cluster fleet-homelab --services fleet --query *), Bash(aws logs describe-log-groups --log-group-name-prefix terraform- --query *), Bash(aws logs start-query *), Bash(aws logs get-query-results *)
---

# Health scan

Plan Task 21's twelve checks, as one read-only script, compared with [`baseline.md`](baseline.md). Nothing here changes the stack. CI also runs the script after every `up` and every apply on merge that changed something, and has Claude compare it with the baseline (the `Fleet checks` workflow's `health-scan` job); if that run's summary or its issue flagged something, start there.

**Keep identifying values out of the conversation.** The script masks the Fleet hostname, the domain, the account ID, ARNs, email and IP addresses. In any follow-up query, limit output with `--query` or Logs Insights `fields`, and never print the Fleet URL, account IDs, ARNs or emails.

## 1. Is the stack up?

`aws rds describe-db-clusters --db-cluster-identifier fleet-homelab --query 'DBClusters[0].Status' --output text`. If it's not `available` (or the cluster doesn't exist), say the stack is down and stop: Fleet's logs and metrics only exist while it's up.

## 2. Run the scan

`scripts/health-scan.sh [hours]` (default 72). Pick the window to fit:
- **After an `up` or an upgrade:** the hours since it started, so the build is in view (about 1–2).
- **Before a teardown, or "how's it doing":** the whole session, or the default 72 (Fleet's log group keeps 5 days, and is destroyed with the stack).

It takes about a minute. If a check says "couldn't read", say which, and carry on with the rest.

## 3. Compare with the baseline

Go through `baseline.md` section by section. For each figure, decide whether it's within what the baseline describes, taking the timing into account (right after an `up` is different from a day in).

For anything outside it, look closer before reporting, read-only:
- **A new error or warning message:** a Logs Insights query for that `msg`, with `fields @timestamp, level, msg, err` and a `limit`, to see when it happened and what it says. Errors that line up with a restart or the `up` are less worrying than ones that keep coming.
- **A metric outside its range:** whether it's a single spike at boot or sustained.

## 4. Report

Briefly:
1. **A verdict line:** ✅ nothing new, ⚠️ something worth a look, or ❌ something wrong now.
2. **What's new or outside the baseline,** each with the figure, what it likely means, and a suggested next step. If nothing is, say so in a line.
3. **One line per section that's normal,** such as "ECS 1/1, logs: only the known `unlock failed` (37)".

If something new turns out to be normal (a new Fleet version's harmless warning, say), offer to add it to `baseline.md` in a pull request. Never change the stack from here: anything that needs fixing is a separate step, with its own yes.
