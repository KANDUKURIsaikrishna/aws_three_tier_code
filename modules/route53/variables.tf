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

variable "domain" {
  description = "Apex domain for the public hosted zone and failover records (e.g. example.com)"
  type        = string
}

variable "primary_alb_dns" {
  description = "Nginx NLB DNS in primary region. Leave empty to skip app records before EKS is ready."
  type        = string
  default     = ""
}

variable "secondary_alb_dns" {
  description = "Nginx NLB DNS in secondary region. Fill after secondary EKS deploy."
  type        = string
  default     = ""
}

variable "enable_cloudfront" {
  description = "When true, the primary record points at cloudfront_domain instead of primary_alb_dns."
  type        = bool
  default     = false
}

variable "cloudfront_domain" {
  description = "CloudFront distribution domain name. Required when enable_cloudfront=true."
  type        = string
  default     = ""
}
