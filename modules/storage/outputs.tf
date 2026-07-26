output "dbbackups_bucket_name" {
  description = "MySQL backups bucket name (→ backup/restore CronJob, D15)."
  value       = aws_s3_bucket.dbbackups.bucket
}

output "dbbackups_bucket_arn" {
  description = "MySQL backups bucket ARN."
  value       = aws_s3_bucket.dbbackups.arn
}

output "planartifacts_bucket_name" {
  description = "Plan-artifacts bucket name (→ gha-iac-plan role, Ansible SSM transfer)."
  value       = aws_s3_bucket.planartifacts.bucket
}

output "planartifacts_bucket_arn" {
  description = "Plan-artifacts bucket ARN."
  value       = aws_s3_bucket.planartifacts.arn
}
