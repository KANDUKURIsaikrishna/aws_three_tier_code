variable "cluster_name" {
  type = string
}

variable "oidc_provider_arn" {
  type = string
}

variable "aws_region" {
  type    = string
  default = "us-west-1"
}

variable "node_role_name" {
  type        = string
  description = "IAM role name of the EKS node group — receives the EBS CSI driver policy"
}
