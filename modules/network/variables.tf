variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid CIDR block, e.g. 10.0.0.0/16."
  }
}

variable "public_subnets" {
  description = "List of public subnets with CIDR and Availability Zone"
  type = list(object({
    cidr = string
    az   = string
  }))

  validation {
    condition     = alltrue([for s in var.public_subnets : can(cidrhost(s.cidr, 0))])
    error_message = "Every public_subnets entry's cidr must be a valid CIDR block."
  }
}

variable "private_subnets" {
  description = "List of private subnets with CIDR and Availability Zone"
  type = list(object({
    cidr = string
    az   = string
  }))

  validation {
    condition     = alltrue([for s in var.private_subnets : can(cidrhost(s.cidr, 0))])
    error_message = "Every private_subnets entry's cidr must be a valid CIDR block."
  }
}
