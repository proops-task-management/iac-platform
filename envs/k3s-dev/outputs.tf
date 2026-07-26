output "admin_cidr_effective" {
  description = "The CIDR actually opened on 6443 (explicit var or auto-detected)."
  value       = local.admin_cidr
}

output "sg_node_id" {
  description = "Node Security Group id."
  value       = module.network.sg_node_id
}

output "server_instance_id" {
  description = "k3s server instance id (→ cluster-up.sh)."
  value       = module.compute_k3s.server_instance_id
}

output "agent_instance_id" {
  description = "k3s agent instance id."
  value       = module.compute_k3s.agent_instance_id
}

output "server_public_ip" {
  description = "Server public IP (→ Route 53 A records via cluster-up.sh; changes on restart)."
  value       = module.compute_k3s.server_public_ip
}

output "server_private_ip" {
  description = "Server private IP (→ SSM /proops/dev/k3s/server-ip; agent join target)."
  value       = module.compute_k3s.server_private_ip
}

output "node_role_arn" {
  description = "Node IAM role ARN (ESO node-IAM auth)."
  value       = module.compute_k3s.node_role_arn
}
