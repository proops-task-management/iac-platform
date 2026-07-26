output "oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider."
  value       = aws_iam_openid_connect_provider.github.arn
}

output "gha_iac_plan_role_arn" {
  description = "Role ARN for terraform plan / fmt / validate (ReadOnly + plan bucket)."
  value       = aws_iam_role.gha_iac_plan.arn
}

output "gha_iac_apply_role_arn" {
  description = "Role ARN for terraform apply (service-scoped; tighten at D9)."
  value       = aws_iam_role.gha_iac_apply.arn
}

output "gha_ecr_push_role_arn" {
  description = "Role ARN for ECR auth + push (EKS window only)."
  value       = aws_iam_role.gha_ecr_push.arn
}

output "gha_ssm_read_role_arn" {
  description = "Role ARN for reading CI secrets under /proops/ci/*."
  value       = aws_iam_role.gha_ssm_read.arn
}
