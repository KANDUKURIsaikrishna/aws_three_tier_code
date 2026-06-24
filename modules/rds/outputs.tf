output "rds_instance_id" {
  description = "RDS instance ID"
  value       = aws_db_instance.db.id
}

output "rds_endpoint" {
  description = "RDS connection endpoint"
  value       = aws_db_instance.db.endpoint
}

output "rds_subnet_group" {
  description = "RDS subnet group name"
  value       = aws_db_subnet_group.rds_subnet_group.name
}

output "master_user_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the RDS master password"
  value       = aws_db_instance.db.master_user_secret[0].secret_arn
}
