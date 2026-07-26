output "zone_id" {
  description = "Route 53 hosted zone id (consumed by cluster-up.sh to upsert A records)."
  value       = aws_route53_zone.this.zone_id
}

output "zone_name" {
  description = "The delegated domain name."
  value       = aws_route53_zone.this.name
}

output "name_servers" {
  description = "The 4 NS records to paste into the DigitalPlat custom-nameserver field (one-time delegation)."
  value       = aws_route53_zone.this.name_servers
}
