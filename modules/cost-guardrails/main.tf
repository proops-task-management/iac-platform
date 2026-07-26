# ===========================================================================
# cost-guardrails — AWS Budgets ($30/mo + $180 total), email alerts.
# AWS Budgets subscribes email addresses directly on each notification, so no
# SNS topic is needed. Thresholds fire at ACTUAL 80/100% and FORECASTED 100%.
# ===========================================================================

locals {
  thresholds = {
    actual_80      = { type = "ACTUAL", threshold = 80 }
    actual_100     = { type = "ACTUAL", threshold = 100 }
    forecasted_100 = { type = "FORECASTED", threshold = 100 }
  }
}

# ------------------------- Monthly budget -----------------------------------
resource "aws_budgets_budget" "monthly" {
  name         = "proops-taskmgmt-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = local.thresholds
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value.threshold
      threshold_type             = "PERCENTAGE"
      notification_type          = notification.value.type
      subscriber_email_addresses = [var.alert_email]
    }
  }
}

# ------------------------- Total (program) budget ---------------------------
# Modeled as an annual budget capped at the program total. AWS has no native
# "lifetime" budget; ANNUALLY over the program year is the standard proxy.
resource "aws_budgets_budget" "total" {
  name              = "proops-taskmgmt-total"
  budget_type       = "COST"
  limit_amount      = tostring(var.total_limit_usd)
  limit_unit        = "USD"
  time_unit         = "ANNUALLY"
  time_period_start = var.total_budget_period_start

  dynamic "notification" {
    for_each = local.thresholds
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value.threshold
      threshold_type             = "PERCENTAGE"
      notification_type          = notification.value.type
      subscriber_email_addresses = [var.alert_email]
    }
  }
}
