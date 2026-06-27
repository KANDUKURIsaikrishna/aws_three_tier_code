variable "db_identifier" {
  description = "RDS instance identifier"
  type        = string
}

variable "db_engine" {
  description = "Database engine (mysql, postgres, etc.)"
  type        = string
  default     = "mysql"
}

variable "db_engine_version" {
  description = "Database engine version"
  type        = string
  default     = "8.0"
}

variable "db_instance_class" {
  description = "RDS instance type"
  type        = string
}

variable "db_allocated_storage" {
  description = "Allocated storage in GB"
  type        = number
}

variable "db_name" {
  description = "Initial database name"
  type        = string
}

variable "db_username" {
  description = "Master username"
  type        = string
}

variable "db_security_group_id" {
  description = "Security group ID attached to RDS"
  type        = string
}

variable "db_subnet_ids" {
  description = "Subnet IDs for RDS subnet group (need at least 2 AZs)"
  type        = list(string)
}

variable "multi_az" {
  description = "Enable Multi-AZ for high availability"
  type        = bool
  default     = true
}

variable "backup_retention_period" {
  description = "Days to retain automated backups (0 disables backups)"
  type        = number
  default     = 7
}

variable "deletion_protection" {
  description = "Prevent accidental deletion of the RDS instance"
  type        = bool
  default     = true
}

variable "kms_key_arn" {
  description = "KMS key ARN for storage encryption. Null = AWS-managed key."
  type        = string
  default     = null
}

variable "max_allocated_storage" {
  description = "Upper limit for RDS storage autoscaling in GB. 0 = disabled."
  type        = number
  default     = 100
}
