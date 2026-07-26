# Role ARNs consumed by the caller workflows (org-level Actions variables, D4 Step 2).
output "oidc_provider_arn" {
  value = module.iam_github_oidc.oidc_provider_arn
}

output "gha_iac_plan_role_arn" {
  value = module.iam_github_oidc.gha_iac_plan_role_arn
}

output "gha_iac_apply_role_arn" {
  value = module.iam_github_oidc.gha_iac_apply_role_arn
}

output "gha_ecr_push_role_arn" {
  value = module.iam_github_oidc.gha_ecr_push_role_arn
}

output "gha_ssm_read_role_arn" {
  value = module.iam_github_oidc.gha_ssm_read_role_arn
}

# --- D9: dns / storage / cost-guardrails ------------------------------------

output "route53_zone_id" {
  description = "Hosted zone id → cluster-up.sh upserts A records here (D10)."
  value       = module.dns.zone_id
}

output "route53_name_servers" {
  description = "Paste these 4 NS into the DigitalPlat custom-nameserver field (one-time delegation)."
  value       = module.dns.name_servers
}

output "dbbackups_bucket_name" {
  description = "MySQL backups bucket (→ backup/restore CronJob, D15)."
  value       = module.storage.dbbackups_bucket_name
}

output "planartifacts_bucket_name" {
  description = "Plan-artifacts bucket (→ gha-iac-plan role, Ansible SSM transfer)."
  value       = module.storage.planartifacts_bucket_name
}
