# ---------------------------------------------------------------------------
# cost-guardrails — inputs (IRD-016 module contract + DOP-011 AC-11-01).
# ACCOUNT-LEVEL spend alerts → live in the `global` root so they OUTLIVE any
# k3s-dev rebuild (a `terraform destroy` of the cluster must never take your
# spend alarms down with it).
#
# The nightly EC2 auto-stop (23:00 ICT) is NOT here — it needs the node
# instance IDs, so it is co-located in the compute-k3s module (born + destroyed
# with the cluster; no orphan scheduler pointing at dead IDs). See IRD-016
# audit log 2026-07-14.
# ---------------------------------------------------------------------------

variable "monthly_limit_usd" {
  type        = number
  description = "Monthly cost budget in USD (DOP-011: $30/mo)."
  default     = 30
}

variable "total_limit_usd" {
  type        = number
  description = "Program-total cost budget in USD (DOP-011: $180 total)."
  default     = 180
}

variable "alert_email" {
  type        = string
  description = "Email subscribed to budget alerts (AWS Budgets sends directly — no SNS needed)."
}

variable "total_budget_period_start" {
  type        = string
  description = "Start of the annual/total budget window (YYYY-MM-DD_HH:MM)."
  default     = "2026-07-01_00:00"
}
