output "public_zone_id" {
  description = "Route53 public hosted zone ID — add NS records at registrar after first apply"
  value       = aws_route53_zone.public.zone_id
}

output "public_name_servers" {
  description = "NS records to set at your domain registrar for Route53 to take authority"
  value       = aws_route53_zone.public.name_servers
}
