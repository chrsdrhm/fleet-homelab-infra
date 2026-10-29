# Health scan baseline

What `scripts/health-scan.sh` normally shows for this stack, from plan Task 21's first run (2026-10-05, three days of use) and the Task 30 run (2026-10-29, just after an `up`). Anything outside this is worth a look. When something new turns out to be normal, add it here in a pull request, with the date.

**Right after an `up` or an upgrade,** several things are expected that wouldn't be later: the migrations add-on scales Fleet to 0 and back, Aurora is newly restored, and the window holds only the build.

## 1. ECS service
- Running 1 of 1, rollout `COMPLETED`, one deployment.
- Events: "has reached a steady state", "registered 1 targets", "has started 1 tasks", and draining during a deployment.
- Stopped tasks, within about an hour of an `up` or upgrade: "Essential container in task exited" (exit 0) and "Scaling activity initiated by deployment". Both are the migrations add-on restarting Fleet. A non-zero exit code, `OutOfMemory` or a task that keeps restarting is not normal.

## 2. Fleet app logs
- Levels: almost all `info`. A handful of lines with a blank level (startup output that isn't JSON).
- `error`: only `unlock failed`, a few dozen at a time, all within minutes of Fleet stopping (a restart, the migrations add-on during `up`, or an upgrade): a cron job loses its database lock as the old task shuts down.
- `error` `invalid role: unassigned`: only if someone signed in through Okta without a role group (the intended refusal).
- `warn`: none, or deprecation notices for API paths that `fleetctl` calls.
- Keyword hits: all 0.

## 3. Load balancer
- 1 healthy target.
- Target 5xx: 0. Load balancer 5xx: 0, or a few in the minute a rebuild's target wasn't up yet.
- 4xx: a few are normal (sign-in redirects, scanners that got past the WAF).
- Response time: average under 0.1 s, maximum about 1 s (cold paths after boot).

## 4. Aurora
- Status `available`, engine `8.0.mysql_aurora.3.13.0`.
- Events after an `up`: cluster created from snapshot, instance created, restarted and shut down (crash recovery during the restore), topology updated. A window reaching back into a teardown also shows the instance and cluster deleted. Otherwise: none.
- Pending maintenance: 0.
- CPU: average 10–15%, maximum about 60% (the restore and migrations).
- CPU credit balance: 0 right after creation, then climbing (past 100 within a day of use). Surplus credits charged: 0. Charged surplus credits mean the instance ran out of credits.
- Freeable memory: minimum about 1.2 GB. Connections: up to about 20.

## 5. Fargate task
- CPU: average a few percent; a spike up to 100% at boot is normal.
- Memory: maximum under 50%.

## 6. Redis
- Events after an `up`: cluster created, node added, and a note that this node type doesn't support persistence (expected: Redis holds nothing that must survive). A window reaching back into a teardown also shows the cluster deleted and its nodes removed.
- Engine CPU under 1%. Evictions: 0.

## 7. WAF
- Allowed is about the load balancer's request count.
- Blocked: anything from a handful to several hundred, growing with how long the stack was up in the window (foreign scanners find a new load balancer within hours, and the US-only rule blocks them). Not a finding on its own; only if allowed requests, 4xx or 5xx rise with it.

## 8. SES
- Sending enabled, enforcement `HEALTHY`, production access `false` (still in the sandbox, by design).
- Sends: a few a day at most, with no bounces or complaints.

## 9. Certificate and DNS
- Certificate `ISSUED`, renewal `ELIGIBLE`, expiring April 2027 (ACM renews it). Flag it if expiry is under 30 days away.
- The Fleet host resolves to at least one address (the load balancer has three), and the zone has its name servers (2 on Cloudflare).

## 10. Budget
- Under the $100 limit. A month with a few sessions comes to about $15–40. Flag a forecast over $80: something may have been left up.

## 11. Fleet and GitHub
- `/healthz` 200. Status endpoints, when checked: `{}` (healthy).
- Latest GitOps run: success. Open Dependabot and secret-scanning alerts: 0 in both repos.
- **In CI (any run, whether after an `up` or started by hand; the report's first line says "in CI"):** the status endpoints are skipped (no Fleet API token), and the Dependabot and secret-scanning counts read `n/a` (the job's token can't read alerts). Just after an `up`, the GitOps run that `up` started may still be running (a blank result instead of success).
