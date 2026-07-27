# ---------------------------------------------------------------------------
# iam-github-oidc — inputs (IRD-016 module contract: org, repos[]).
# repos[] is split into three trust groups because each role trusts a
# different set of source repos (least-privilege on the *identity* side).
# ---------------------------------------------------------------------------

variable "org" {
  type        = string
  description = "GitHub org that owns the repos, e.g. proops-task-management."
}

variable "iac_repos" {
  type        = list(string)
  description = "Repos allowed to assume the IaC plan/apply roles (normally just iac-platform)."
}

variable "ci_repos" {
  type        = list(string)
  description = "Service repos allowed to read CI secrets from SSM (the 5 services)."
}

variable "ecr_repos" {
  type        = list(string)
  description = "Repos allowed to push to ECR (EKS window only, IRD-023 — normally the 5 services)."
}

variable "ssm_ci_path" {
  type        = string
  description = "SSM parameter path (with trailing wildcard) the ssm-read role may read."
  default     = "/proops/ci/*"
}

variable "plan_artifacts_bucket_name" {
  type        = string
  description = "Name of the plan-artifacts S3 bucket (created by the storage module at D9). The plan role gets RW here for /review-plan artifacts."
}

variable "lock_table_name" {
  type        = string
  default     = "proops-taskmgmt-tflock-apse1"
  description = "Terraform remote-state DynamoDB lock table (matches backend.tf). The apply role needs Get/Put/DeleteItem on it to take the state lock; the plan role uses -lock=false and does not."
}

variable "iac_apply_actions" {
  type        = list(string)
  description = <<-EOT
    Service actions the gha-iac-apply role may perform. SERVICE-SCOPED for now
    (action wildcards, resources = "*"); TODO(D9): tighten to resource ARNs once
    the global/k3s-dev roots exist. Never attach AdministratorAccess.
  EOT
}
