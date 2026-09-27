module "fleet" {
  source = "github.com/fleetdm/fleet-terraform?depth=1&ref=tf-mod-root-v1.31.1"

  certificate_arn = aws_acm_certificate_validation.fleet.certificate_arn

  vpc = {
    name = "fleet-homelab"
    azs  = ["us-east-1a", "us-east-1b", "us-east-1c"]
  }

  ecs_cluster = {
    cluster_name = "fleet-homelab"
  }

  alb_config = {
    name         = "fleet-homelab"
    idle_timeout = 905
  }

  rds_config = {
    name           = "fleet-homelab"
    instance_class = "db.t4g.medium"
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
  name              = "/aws/ecs/containerinsights/fleet-homelab/performance"
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
