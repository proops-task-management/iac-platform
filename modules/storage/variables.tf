# ---------------------------------------------------------------------------
# storage — inputs (IRD-016 module contract).
# Two long-lived buckets in the `global` root:
#   - db backups (MySQL dumps), 14-day lifecycle expiry
#   - plan artifacts (terraform plan.txt for Agent C /review-plan + Ansible SSM transfer)
# Provider 6.x sends tags in the CreateBucket call — required because this
# account denies untagged s3:CreateBucket (IRD-013).
# ---------------------------------------------------------------------------

variable "dbbackups_bucket_name" {
  type        = string
  description = "MySQL backups bucket name (IRD-013 naming): proops-taskmgmt-global-s3-apse1-dbbackups."
}

variable "planartifacts_bucket_name" {
  type        = string
  description = "Plan-artifacts bucket name. MUST match iam-github-oidc's plan_artifacts_bucket_name (the gha-iac-plan role has RW here)."
}

variable "backup_retention_days" {
  type        = number
  description = "Days to keep MySQL dump objects before lifecycle expiry."
  default     = 14
}

variable "planartifacts_retention_days" {
  type        = number
  description = "Days to keep plan artifacts / clean up incomplete uploads."
  default     = 30
}
