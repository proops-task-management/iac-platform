# Operator-supplied + defaulted inputs for the global root (IRD-016).
# Defaults are the known-good values so `terraform plan` runs with an empty
# tfvars; override in terraform.tfvars (gitignored) when they change.

variable "aws_region" {
  type    = string
  default = "ap-southeast-1"
}

variable "owner" {
  type    = string
  default = "minh_dt"
}

variable "email" {
  type    = string
  default = "tuanminh.dinh.work@gmail.com"
}

variable "project" {
  type    = string
  default = "proops-taskmgmt"
}

variable "cost_center" {
  type    = string
  default = "training"
}

variable "org" {
  type        = string
  default     = "proops-task-management"
  description = "GitHub org that owns the repos."
}

variable "iac_repos" {
  type        = list(string)
  default     = ["iac-platform"]
  description = "Repos allowed to assume the IaC plan/apply roles."
}

variable "ci_repos" {
  type        = list(string)
  default     = ["api-gateway", "user-service", "task-service", "notification-service", "frontend-service"]
  description = "Service repos allowed to read CI secrets from SSM."
}

variable "ecr_repos" {
  type        = list(string)
  default     = ["api-gateway", "user-service", "task-service", "notification-service", "frontend-service"]
  description = "Repos allowed to push to ECR (EKS window only)."
}

variable "ssm_ci_path" {
  type    = string
  default = "/proops/ci/*"
}

variable "plan_artifacts_bucket_name" {
  type        = string
  default     = "proops-taskmgmt-global-s3-apse1-planartifacts"
  description = "Plan-artifacts bucket (created by the storage module at D9); the plan role gets RW here."
}

# --- D9 additions: dns zone, buckets, budgets -------------------------------

variable "domain" {
  type        = string
  default     = "taskmgmt.dpdns.org"
  description = "Apex domain for the Route 53 zone. Free DigitalPlat domain (MIN-13 option B), registered 2026-07-29, expires 2027-07-29. Delegate its NS to route53_name_servers — a zone without delegation resolves nothing (TSG-029, IRD-016 §Prerequisites). Renamed from proops-taskmgmt.* (MIN-59): that name was already taken at the registrar."
}

variable "dbbackups_bucket_name" {
  type        = string
  default     = "proops-taskmgmt-global-s3-apse1-dbbackups"
  description = "MySQL backups bucket (14-day lifecycle)."
}

variable "backup_retention_days" {
  type        = number
  default     = 14
  description = "Days to keep MySQL dump objects (IRD-016)."
}

variable "monthly_limit_usd" {
  type        = number
  default     = 30
  description = "Monthly AWS Budget cap (DOP-011)."
}

variable "total_limit_usd" {
  type        = number
  default     = 180
  description = "Program-total AWS Budget cap (DOP-011)."
}

variable "alert_email" {
  type        = string
  default     = "tuanminh.dinh.work@gmail.com"
  description = "Email subscribed to budget alerts."
}

variable "iac_apply_actions" {
  type = list(string)
  default = [
    "ec2:*",
    "iam:*",
    "route53:*",
    "s3:*",
    "budgets:*",
    "scheduler:*",
    "events:*",
    "ssm:*",
    "logs:*",
    "sns:*",
    "kms:*",
    "autoscaling:*",
  ]
  description = "Service-scoped apply permissions; TODO(D9) tighten to resource ARNs."
}
