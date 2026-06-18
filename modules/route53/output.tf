output "rds_private_zone_id" {
  description = "ID of the private hosted zone for RDS"
  value       = aws_route53_zone.rds_private.zone_id
}

output "rds_record_fqdn" {
  description = "FQDN for the RDS private DNS record"
  value       = aws_route53_record.rds_endpoint.fqdn
}
