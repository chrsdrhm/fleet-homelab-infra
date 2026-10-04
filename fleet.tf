locals {
  # The Container Insights log group name embeds the cluster name, so the two have
  # to move together. A typo in either would silently recreate the untagged
  # group AWS makes on its own (see aws_cloudwatch_log_group.container_insights).
  cluster_name = "fleet-homelab"
}

module "fleet" {
  source = "github.com/fleetdm/fleet-terraform?depth=1&ref=tf-mod-root-v1.31.1"

  certificate_arn = aws_acm_certificate_validation.fleet.certificate_arn

  vpc = {
    name = "fleet-homelab"
    # db.t4g.medium (Aurora MySQL 3.08) is only orderable in us-east-1c and us-east-1f.
    # With 1a/1b/1c, Aurora could only ever place the instance in 1c, and a build failed
    # when 1c had no spare capacity (InvalidVPCNetworkStateFault). Keep BOTH orderable
    # zones in the set so there are two chances; the module wants three zones in total.
    # 1f takes 1b's old slot: subnets are matched to zones by position, so this
    # replaces one subnet per tier instead of shifting every zone.
    azs = ["us-east-1a", "us-east-1f", "us-east-1c"]
  }

  ecs_cluster = {
    cluster_name = local.cluster_name
  }

  alb_config = {
    name         = "fleet-homelab"
    idle_timeout = 905
  }

  rds_config = {
    name = "fleet-homelab"
    # db.t3.medium (2 vCPU / 4 GiB, x86) instead of db.t4g.medium (same size, ARM): on
    # 2026-10-04 three rebuild attempts in a row failed with InsufficientDBInstanceCapacity
    # for db.t4g.medium in all three zones. Same sizing, so this is a straight swap.
    instance_class = "db.t3.medium"
    # Aurora MySQL 3.13.0 = MySQL 8.0.45. Fleet states a minimum of MySQL 8.0.44 (docs +
    # its CI: 8.0.44 on every change, 8.4.8 nightly), and AWS ends standard support for
    # Aurora 3.08/3.09 on 2026-08-31 then force-upgrades them. The module default
    # (3.08.2) is below both, so it must be pinned here.
    engine_version = "8.0.mysql_aurora.3.13.0"
    replicas       = 1
    db_parameters = {
      sort_buffer_size = 8388608
    }
    snapshot_identifier = var.rds_snapshot_identifier

    # Restore-from-snapshot compatibility: the module defaults are
    # monitoring_interval = 10 and Performance Insights on, and Fleet's own
    # byo-vpc/scripts/rds_storage_kms_migration.sh notes that
    # RestoreDBClusterFromSnapshot rejects both for non-Limitless Aurora.
    monitoring_interval = 0
    observability = {
      performance_insights_enabled = false
    }
  }

  redis_config = {
    name          = "fleet-homelab"
    instance_type = "cache.t4g.small"
    cluster_size  = 1
    parameter = [
      { name = "client-output-buffer-limit-pubsub-hard-limit", value = 0 },
      { name = "client-output-buffer-limit-pubsub-soft-limit", value = 0 },
      { name = "client-output-buffer-limit-pubsub-soft-seconds", value = 0 },
    ]
  }

  fleet_config = {
    image = "fleetdm/fleet:v4.92.0"
    cpu   = 512
    mem   = 4096

    private_key_secret_arn = aws_secretsmanager_secret.fleet_server_private_key.arn

    software_installers = {
      create_bucket = false
      bucket_name   = aws_s3_bucket.software_installers.bucket
    }
    extra_iam_policies = concat(
      [aws_iam_policy.software_installers.arn],
      module.ses.fleet_extra_iam_policies
    )

    autoscaling = {
      min_capacity = 1
      max_capacity = 2
    }

    extra_environment_variables = merge(
      {
        FLEET_LICENSE_KEY          = var.fleet_license_key
        FLEET_LOGGING_JSON         = "true"
        FLEET_MYSQL_MAX_OPEN_CONNS = "10"
        FLEET_REDIS_MAX_OPEN_CONNS = "50"
      },
      module.ses.fleet_extra_environment_variables
    )

    extra_secrets                = module.mdm.extra_secrets
    extra_execution_iam_policies = module.mdm.extra_execution_iam_policies
  }
}

# Fleet refuses to start until the database schema is migrated, and nothing
# in the root module runs migrations. This addon scales the service to 0,
# runs `fleet prepare db` as a one-off Fargate task, then scales back up —
# and re-triggers whenever the task definition revision changes, so it also
# covers Fleet image bumps and the first boot after a snapshot restore.
# Copied from upstream example/main.tf (tf-mod-addon-migrations-v2.3.0).
module "migrations" {
  source                   = "github.com/fleetdm/fleet-terraform/addons/migrations?depth=1&ref=tf-mod-addon-migrations-v2.3.0"
  ecs_cluster              = module.fleet.byo-vpc.byo-db.byo-ecs.service.cluster
  task_definition          = module.fleet.byo-vpc.byo-db.byo-ecs.task_definition.family
  task_definition_revision = module.fleet.byo-vpc.byo-db.byo-ecs.task_definition.revision
  subnets                  = module.fleet.byo-vpc.byo-db.byo-ecs.service.network_configuration[0].subnets
  security_groups          = module.fleet.byo-vpc.byo-db.byo-ecs.service.network_configuration[0].security_groups
  ecs_service              = module.fleet.byo-vpc.byo-db.byo-ecs.service.name
  desired_count            = module.fleet.byo-vpc.byo-db.byo-ecs.appautoscaling_target.min_capacity
  min_capacity             = module.fleet.byo-vpc.byo-db.byo-ecs.appautoscaling_target.min_capacity
  max_capacity             = module.fleet.byo-vpc.byo-db.byo-ecs.appautoscaling_target.max_capacity

  depends_on = [
    module.fleet,
  ]
}

# ECS Container Insights writes to this log group and AWS auto-creates it
# untagged, where it outlives `terraform destroy`. Declaring it here means it
# gets the default tags and is removed on teardown. (No depends_on needed:
# metrics only start flowing minutes after the cluster has tasks.)
resource "aws_cloudwatch_log_group" "container_insights" {
  name              = "/aws/ecs/containerinsights/${local.cluster_name}/performance"
  retention_in_days = 1
}

resource "aws_route53_record" "fleet_alb" {
  zone_id = aws_route53_zone.fleet.zone_id
  name    = var.fleet_subdomain
  type    = "A"

  alias {
    name                   = module.fleet.byo-vpc.byo-db.alb.lb_dns_name
    zone_id                = module.fleet.byo-vpc.byo-db.alb.lb_zone_id
    evaluate_target_health = true
  }
}
