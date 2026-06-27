resource "random_password" "db_password" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}?"
}

resource "aws_secretsmanager_secret" "db_credentials" {
  name                    = "/bookstore/db-credentials"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    DB_USERNAME = var.db_username
    DB_PASSWORD = random_password.db_password.result
    DB_HOST     = aws_db_instance.db.endpoint
  })
}

resource "aws_db_subnet_group" "rds_subnet_group" {
  name       = "rds-subnet-group"
  subnet_ids = var.db_subnet_ids
  tags       = { Name = "rds-subnet-group" }
}

resource "aws_db_instance" "db" {
  identifier        = var.db_identifier
  engine            = var.db_engine
  engine_version    = var.db_engine_version
  instance_class    = var.db_instance_class
  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.max_allocated_storage == 0 ? null : var.max_allocated_storage

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db_password.result

  # ── High Availability ─────────────────────────────────────────────
  multi_az = var.multi_az

  # ── Encryption at rest ────────────────────────────────────────────
  storage_encrypted = true
  kms_key_id        = var.kms_key_arn  # leave null → uses AWS-managed key

  # ── Backups ───────────────────────────────────────────────────────
  backup_retention_period = var.backup_retention_period
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"

  # ── Final snapshot on destroy ─────────────────────────────────────
  # skip_final_snapshot=true avoids "snapshot already exists" errors on
  # repeated destroy/apply cycles. RDS automated backups (retention=7d)
  # already provide point-in-time recovery for production use.
  skip_final_snapshot = true
  deletion_protection = var.deletion_protection

  # ── Performance & Monitoring ──────────────────────────────────────
  performance_insights_enabled = false
  monitoring_interval          = 60
  monitoring_role_arn                   = aws_iam_role.rds_monitoring.arn
  enabled_cloudwatch_logs_exports       = ["error", "general", "slowquery"]

  publicly_accessible    = false
  vpc_security_group_ids = [var.db_security_group_id]
  db_subnet_group_name   = aws_db_subnet_group.rds_subnet_group.name

  tags = { Name = var.db_identifier }
}

# Enhanced Monitoring IAM role
resource "aws_iam_role" "rds_monitoring" {
  name = "${var.db_identifier}-rds-monitoring"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}
