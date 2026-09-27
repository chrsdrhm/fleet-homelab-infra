# Safety net against forgetting to tear the stack down. Alerts every $10 of actual
# spend up to the $100 limit. Budgets data refreshes only up to ~3x/day (8-12h apart),
# so this is a "within about a day" alarm, not a real-time one.
resource "aws_budgets_budget" "fleet_homelab" {
  name         = "fleet-homelab-monthly"
  budget_type  = "COST"
  limit_amount = "100"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = range(10, 101, 10)
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "ABSOLUTE_VALUE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [var.budget_alert_email]
    }
  }
}
