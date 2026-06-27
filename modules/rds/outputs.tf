output "rds_instance_id" {
  description = "RDS instance ID"
  value       = aws_db_instance.db.id
}

output "rds_instance_arn" {
  description = "RDS instance ARN — used for cross-region backup replication"
  value       = aws_db_instance.db.arn
}

output "rds_endpoint" {
  description = "RDS connection endpoint"
  value       = aws_db_instance.db.endpoint
}

output "rds_subnet_group" {
  description = "RDS subnet group name"
  value       = aws_db_subnet_group.rds_subnet_group.name
}

output "db_credentials_secret_arn" {
  description = "ARN of the Secrets Manager secret at /bookstore/db-credentials (DB_USERNAME, DB_PASSWORD, DB_HOST)"
  value       = aws_secretsmanager_secret.db_credentials.arn
}
