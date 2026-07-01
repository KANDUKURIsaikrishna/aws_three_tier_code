# RDS cross-region backup replication.
# Requires an explicit CMK in the secondary region — AWS-managed keys are
# region-scoped and cannot be used for cross-region replication.
# Set dr_kms_key_id to a CMK ARN in var.secondary_region to enable.
resource "aws_db_instance_automated_backups_replication" "secondary" {
  count                  = var.dr_kms_key_id != "" ? 1 : 0
  provider               = aws.secondary
  source_db_instance_arn = module.rds.rds_instance_arn
  retention_period       = 7
  kms_key_id             = var.dr_kms_key_id
}
