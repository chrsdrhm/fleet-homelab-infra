# The Fleet server image that fleet.tf deploys. It's never built: it only holds the version.
# The daily release check (fleet-checks.yml) flags a newer Fleet release, and an upgrade
# is a pull request changing this line (docs/upgrading-fleet.md; snapshot first).
FROM fleetdm/fleet:v4.94.0
