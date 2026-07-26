output "server_instance_id" {
  description = "k3s server EC2 instance id (→ cluster-up.sh start-instances, SSM)."
  value       = aws_instance.server.id
}

output "agent_instance_id" {
  description = "k3s agent EC2 instance id."
  value       = aws_instance.agent.id
}

output "server_public_ip" {
  description = "Server public IP (→ Route 53 A records via cluster-up.sh; changes on restart)."
  value       = aws_instance.server.public_ip
}

output "server_private_ip" {
  description = "Server private IP (→ SSM /proops/dev/k3s/server-ip; agent join target)."
  value       = aws_instance.server.private_ip
}

output "agent_public_ip" {
  description = "Agent public IP."
  value       = aws_instance.agent.public_ip
}

output "node_role_arn" {
  description = "Node IAM role ARN (ESO node-IAM auth; consumers may attach more policies)."
  value       = aws_iam_role.node.arn
}

output "node_role_name" {
  description = "Node IAM role name."
  value       = aws_iam_role.node.name
}

output "ami_id" {
  description = "AMI id the nodes launched from (resolved AL2023 x86_64)."
  value       = local.ami_id
}
