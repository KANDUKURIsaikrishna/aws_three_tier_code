variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "bookstore-eks"
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.31"
}

variable "subnet_ids" {
  description = "Private subnet IDs for the control plane and node groups"
  type        = list(string)
}

variable "node_instance_type" {
  description = "EC2 instance type for worker nodes"
  type        = string
  default     = "t3.medium"
}

variable "node_min_size" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 1

  validation {
    condition     = var.node_min_size >= 0
    error_message = "node_min_size must be 0 or greater."
  }
}

variable "node_max_size" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 2

  validation {
    condition     = var.node_max_size >= 1
    error_message = "node_max_size must be 1 or greater."
  }
}

variable "node_desired_size" {
  description = "Desired number of worker nodes at rest"
  type        = number
  default     = 1

  validation {
    condition     = var.node_desired_size >= 0
    error_message = "node_desired_size must be 0 or greater."
  }
}

variable "prefix" {
  description = "Prefix applied to all IAM and resource names"
  type        = string
  default     = "bookstore"
}

variable "public_access_cidrs" {
  description = "CIDR blocks allowed to reach the public EKS API endpoint. Restrict to admin IP ranges in production (e.g. [\"203.0.113.0/24\"]). Default allows all — narrow before go-live."
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = alltrue([for c in var.public_access_cidrs : can(cidrhost(c, 0))])
    error_message = "public_access_cidrs must be a list of valid CIDR blocks, e.g. [\"203.0.113.0/24\"]."
  }
}

variable "region" {
  description = "AWS region — nodes use this to call ec2:DescribeInstances at boot, discovering the monitoring EC2's private IP for Fluent Bit's Loki output. Not templated as a static loki_url: that would need this module to depend on module.monitoring_ec2's actual instance, which itself depends on this module's cluster_name -- a circular dependency. Runtime discovery via the same AWS-API-lookup pattern already used elsewhere in this project (see modules/monitoring-ec2's own node-IP discovery) sidesteps it entirely. See docs/TROUBLESHOOTING.md OBS-050."
  type        = string
}

variable "admin_principal_arns" {
  description = "IAM principal ARNs granted cluster-admin via EKS access entries (AmazonEKSClusterAdminPolicy). bootstrap_cluster_creator_admin_permissions only fires once at cluster creation and doesn't cover later operators/CI roles — this list is the persistent, re-appliable alternative."
  type        = list(string)
  default     = []
}
