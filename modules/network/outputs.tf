output "sg_node_id" {
  description = "Security Group ID for the k3s nodes (consumed by compute-k3s)."
  value       = aws_security_group.node.id
}

output "vpc_id" {
  description = "Default VPC ID the nodes run in."
  value       = data.aws_vpc.default.id
}

output "subnet_ids" {
  description = "Default subnets available for node placement."
  value       = data.aws_subnets.default.ids
}
