resource "random_password" "fleet_server_private_key" {
  length  = 32
  special = true

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_secretsmanager_secret" "fleet_server_private_key" {
  name                    = "fleet-homelab/fleet-server-private-key"
  recovery_window_in_days = 30

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_secretsmanager_secret_version" "fleet_server_private_key" {
  secret_id     = aws_secretsmanager_secret.fleet_server_private_key.id
  secret_string = random_password.fleet_server_private_key.result
}
