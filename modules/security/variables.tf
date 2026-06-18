variable "vpc_id" {
  description = "VPC ID where security groups are created"
  type        = string
}

variable "prefix" {
  description = "Prefix applied to all resource names"
  type        = string
  default     = "bookstore"
}
