# RDS cross-region backup replication.
# Requires the secondary-region provider alias — cannot be passed into a child
# module without explicit provider configuration blocks inside that module.
resource "aws_db_instance_automated_backups_replication" "secondary" {
  provider               = aws.secondary
  source_db_instance_arn = module.rds.rds_instance_arn
  retention_period       = 7
}
