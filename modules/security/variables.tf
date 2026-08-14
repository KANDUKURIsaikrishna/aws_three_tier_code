variable "vpc_id" {
  description = "VPC ID where security groups are created"
  type        = string
}

variable "prefix" {
  description = "Prefix applied to all resource names"
  type        = string
  default     = "bookstore"
}

variable "eks_node_cidr_blocks" {
  description = "CIDR blocks of the EKS node private subnets, allowed to reach RDS on 3306. Previously this rule opened 3306 to the entire VPC CIDR (public subnets, RDS's own subnets, everything) despite its description claiming EKS-nodes-only — see docs/TROUBLESHOOTING.md OBS-049."
  type        = list(string)

  validation {
    condition     = alltrue([for c in var.eks_node_cidr_blocks : can(cidrhost(c, 0))])
    error_message = "eks_node_cidr_blocks must be a list of valid CIDR blocks."
  }
}
