variable "vpc_id" {
  description = "VPC ID for the private hosted zone association"
  type        = string
}

variable "rds_private_zone_name" {
  description = "Name of the private Route 53 hosted zone for internal RDS DNS"
  type        = string
  default     = "bookstore.internal"
}

variable "rds_record_name" {
  description = "DNS record name for the RDS endpoint within the private zone"
  type        = string
  default     = "db.bookstore.internal"
}

variable "rds_endpoint" {
  description = "RDS instance endpoint to create a CNAME record for"
  type        = string
}
