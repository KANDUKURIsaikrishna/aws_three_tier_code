variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-west-1"
}

variable "environment" {
  description = "Deployment environment tag applied to all resources"
  type        = string
  default     = "prod"
}

variable "domain" {
  description = "Primary domain for ACM cert and ingress host rules (e.g. example.com)"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository in owner/name format — scopes the OIDC CI role trust policy"
  type        = string
}
