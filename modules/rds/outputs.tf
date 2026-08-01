output "rds_instance_id" {
  description = "RDS instance ID"
  value       = aws_db_instance.db.id
}

output "rds_instance_arn" {
  description = "RDS instance ARN — used for cross-region backup replication"
  value       = aws_db_instance.db.arn
}

output "rds_endpoint" {
  # Deliberately .address, NOT .endpoint. aws_db_instance.endpoint returns
  # "host:port" combined — every consumer of this output (the admin
  # Secrets Manager entry's DB_HOST, catalog-service's DB_HOST, the private
  # Route53 CNAME target) treats it as a bare hostname and passes it
  # straight to a driver's `host` parameter or a DNS record value, neither
  # of which can parse an embedded port. Confirmed live: `mysql -h
  # "host:3306"` fails with "ERROR 2005: Unknown MySQL server host" — DNS
  # resolution chokes on the colon. This means no database connection
  # anywhere in this project's history ever actually worked; it was never
  # exercised end-to-end until this session. See TROUBLESHOOTING.md OBS-017.
  # Port is (and always was) handled separately by consumers, e.g. the
  # DB_PORT key already present alongside DB_HOST in every secret/configmap.
  description = "RDS connection hostname (bare address, no port — see comment above)"
  value       = aws_db_instance.db.address
}

output "rds_subnet_group" {
  description = "RDS subnet group name"
  value       = aws_db_subnet_group.rds_subnet_group.name
}

output "db_credentials_secret_arn" {
  description = "ARN of the Secrets Manager secret at /bookstore/db-credentials (DB_USERNAME, DB_PASSWORD, DB_HOST)"
  value       = aws_secretsmanager_secret.db_credentials.arn
}
