# ---------------------------------------------------------------------------
# session-manager-prefs — inputs (IRD-016 module contract, MIN-83).
# ---------------------------------------------------------------------------

variable "idle_session_timeout_minutes" {
  type        = number
  description = "Minutes of no traffic after which Session Manager closes a session. Covers the operator's k3s API tunnel and Ansible's aws_ssm connection. AWS allows 1-60; the AWS default when no preferences document exists is 20."

  validation {
    condition     = var.idle_session_timeout_minutes >= 1 && var.idle_session_timeout_minutes <= 60 && floor(var.idle_session_timeout_minutes) == var.idle_session_timeout_minutes
    error_message = "idle_session_timeout_minutes must be a whole number from 1 to 60 (the Session Manager limit)."
  }
}
