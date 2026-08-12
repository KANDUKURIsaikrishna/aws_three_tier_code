variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
}

variable "public_subnets" {
  description = "List of public subnets with CIDR and Availability Zone"
  type = list(object({
    cidr = string
    az   = string
  }))
}

variable "private_subnets" {
  description = "List of private subnets with CIDR and Availability Zone"
  type = list(object({
    cidr = string
    az   = string
  }))
}
