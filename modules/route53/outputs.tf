output "public_zone_id" {
  description = "Route53 public hosted zone ID — created once via scripts/init-domain.sh, looked up here"
  value       = data.aws_route53_zone.public.zone_id
}

output "public_name_servers" {
  description = "NS records already set at your domain registrar by scripts/init-domain.sh — informational only"
  value       = data.aws_route53_zone.public.name_servers
}
