# The Fleet server image that fleet.tf deploys. It's never built: it only holds the version.
# The nightly Terraform run opens an issue when Fleet has a newer release, and an upgrade
# is a pull request changing this line (docs/upgrading-fleet.md; snapshot first).
FROM fleetdm/fleet:v4.93.0
