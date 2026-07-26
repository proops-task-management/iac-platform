# The global root owns the long-lived, apply-once resources (D4 + D9):
# GitHub->AWS OIDC trust, the DNS hosted zone, the S3 buckets, and the account
# cost guardrails. These OUTLIVE the daily k3s-dev cluster (a destroy of
# k3s-dev never touches this root).
module "iam_github_oidc" {
  source = "../../modules/iam-github-oidc"

  org                        = var.org
  iac_repos                  = var.iac_repos
  ci_repos                   = var.ci_repos
  ecr_repos                  = var.ecr_repos
  ssm_ci_path                = var.ssm_ci_path
  plan_artifacts_bucket_name = var.plan_artifacts_bucket_name
  iac_apply_actions          = var.iac_apply_actions
}

# DNS hosted zone (D9). Zone only — A records are upserted by cluster-up.sh
# (D10) because the node IP changes daily. Delegate the DigitalPlat domain to
# the `route53_name_servers` output (one-time).
module "dns" {
  source = "../../modules/dns"

  domain = var.domain
}

# S3 buckets (D9): MySQL backups (14-day lifecycle) + plan artifacts. The
# plan-artifacts name MUST equal the one the OIDC plan role was granted RW on.
module "storage" {
  source = "../../modules/storage"

  dbbackups_bucket_name     = var.dbbackups_bucket_name
  planartifacts_bucket_name = var.plan_artifacts_bucket_name
  backup_retention_days     = var.backup_retention_days
}

# Account cost guardrails (D9): $30/mo + $180 total budgets → email.
module "cost_guardrails" {
  source = "../../modules/cost-guardrails"

  monthly_limit_usd = var.monthly_limit_usd
  total_limit_usd   = var.total_limit_usd
  alert_email       = var.alert_email
}
