variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the EKS cluster OIDC provider — used for IRSA role creation"
  type        = string
}

variable "node_role_name" {
  description = "IAM role name of the EKS node group — receives the EBS CSI driver policy"
  type        = string
}

variable "loki_url" {
  description = "Loki base URL on the monitoring EC2 instance (e.g. http://<eip>:3100) — Promtail pushes logs here"
  type        = string
}
