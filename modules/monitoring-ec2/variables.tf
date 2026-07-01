variable "vpc_id" {
  description = "VPC where the monitoring EC2 instance is deployed"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR block — allows Promtail in EKS to push logs to Loki"
  type        = string
}

variable "public_subnet_id" {
  description = "Public subnet for the monitoring EC2 instance"
  type        = string
}

variable "eip_allocation_id" {
  description = "Elastic IP allocation ID to associate with the monitoring instance"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name — used to discover node IPs at boot"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "eks_node_sg_id" {
  description = "EKS cluster security group ID — monitoring EC2 gets inbound permission to scrape NodePorts 30808/30809"
  type        = string
}

variable "grafana_admin_secret_arn" {
  description = "Secrets Manager secret ARN for Grafana admin password — EC2 IAM policy allows GetSecretValue on this ARN"
  type        = string
}

variable "grafana_admin_secret_name" {
  description = "Secrets Manager secret name (path) for Grafana admin password"
  type        = string
  default     = "/bookstore/grafana-admin"
}

variable "admin_cidr_blocks" {
  description = "CIDRs allowed to access Grafana (3000) and Prometheus (9090)"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "instance_type" {
  description = "EC2 instance type for the monitoring server"
  type        = string
  default     = "t3.small"
}
