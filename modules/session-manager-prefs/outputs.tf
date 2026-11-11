output "document_name" {
  description = "Name of the Session Manager preferences document (AWS-reserved)."
  value       = aws_ssm_document.this.name
}

output "idle_session_timeout_minutes" {
  description = "The configured idle timeout in minutes, as applied to the document."
  value       = var.idle_session_timeout_minutes
}
