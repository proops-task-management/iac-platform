output "monthly_budget_name" {
  description = "Monthly cost budget name."
  value       = aws_budgets_budget.monthly.name
}

output "total_budget_name" {
  description = "Program-total cost budget name."
  value       = aws_budgets_budget.total.name
}
