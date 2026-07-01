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

variable "vpc_id" {
  description = "VPC ID where the cluster is deployed"
  type        = string
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
}

variable "node_max_size" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 2
}

variable "node_desired_size" {
  description = "Desired number of worker nodes at rest"
  type        = number
  default     = 1
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
}

variable "loki_url" {
  description = "Loki push URL on the monitoring EC2 (e.g. http://<eip>:3100) — Fluent Bit on nodes ships container logs here. Empty string disables Fluent Bit output."
  type        = string
  default     = ""
}
