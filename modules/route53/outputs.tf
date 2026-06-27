output "rds_private_zone_id" {
  description = "ID of the private hosted zone for RDS"
  value       = aws_route53_zone.rds_private.zone_id
}

output "rds_record_fqdn" {
  description = "FQDN for the RDS private DNS record"
  value       = aws_route53_record.rds_endpoint.fqdn
}

output "public_zone_id" {
  description = "Route53 public hosted zone ID — add NS records at registrar after first apply"
  value       = aws_route53_zone.public.zone_id
}

output "public_name_servers" {
  description = "NS records to set at your domain registrar for Route53 to take authority"
  value       = aws_route53_zone.public.name_servers
}
