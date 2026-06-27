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

variable "secondary_region" {
  description = "Secondary AWS region for active-passive failover"
  type        = string
  default     = "us-east-1"
}

variable "primary_alb_dns" {
  description = "Nginx NLB DNS in primary region (us-west-1). Run: kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'. Leave empty to skip Route53 app records (first apply before EKS ready)."
  type        = string
  default     = ""
}

variable "secondary_alb_dns" {
  description = "Nginx NLB DNS in secondary region. Fill after secondary EKS is deployed. Leave empty to skip secondary failover record."
  type        = string
  default     = ""
}

variable "enable_cloudfront" {
  description = "Set to true to put CloudFront in front of the frontend. Requires primary_alb_dns to be set. CloudFront ACM cert is created in us-east-1 automatically."
  type        = bool
  default     = false
}
