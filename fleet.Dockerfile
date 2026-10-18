# The Fleet server image that fleet.tf deploys. It's never built: it's here so Dependabot's
# docker ecosystem can see the version and open a pull request for each new Fleet release.
# Take a snapshot before merging one (docs/upgrading-fleet.md).
FROM fleetdm/fleet:v4.93.0
