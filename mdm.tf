module "mdm" {
  source = "github.com/fleetdm/fleet-terraform//addons/mdm?depth=1&ref=tf-mod-addon-mdm-v2.2.0"

  apn_secret_name    = null         # Apple APNs cert is uploaded in the Fleet UI (Task 8), not via a secret
  scep_secret_name   = "fleet-scep" # same as the module default, kept explicit: this secret outlives teardown and its name must never drift
  abm_secret_name    = null
  enable_apple_mdm   = false # keeps the Apple env vars out of the task definition
  enable_windows_mdm = true  # wires fleet-scep -> FLEET_MDM_WINDOWS_WSTEP_IDENTITY_*
}
