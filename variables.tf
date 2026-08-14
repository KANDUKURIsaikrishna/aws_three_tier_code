variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-west-1"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-\\d$", var.aws_region))
    error_message = "aws_region must look like a real AWS region code, e.g. us-west-1."
  }
}

variable "environment" {
  description = "Deployment environment tag applied to all resources"
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "cost_center" {
  description = "Cost-allocation tag applied to every resource, for chargeback/FinOps grouping beyond Project/Environment"
  type        = string
  default     = "bookstore-platform"
}

variable "domain" {
  description = "Primary domain for ACM cert and ingress host rules (e.g. example.com)"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$", var.domain))
    error_message = "domain must be a valid DNS domain, e.g. example.com."
  }
}

variable "github_repo" {
  description = "GitHub repository in owner/name format — scopes the OIDC CI role trust policy"
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$", var.github_repo))
    error_message = "github_repo must be in owner/repo format, e.g. octocat/hello-world."
  }
}

variable "secondary_region" {
  description = "Secondary AWS region for DR failover, IF enable_dr_replication is true (see that variable — this region alone does not turn replication on). Always needs a valid region string regardless, since the \"secondary\" provider alias in providers.tf is configured with it unconditionally. Default: us-west-2 (Oregon). CloudFront ACM always uses us-east-1 regardless of this value."
  type        = string
  default     = "us-west-2"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-\\d$", var.secondary_region))
    error_message = "secondary_region must look like a real AWS region code, e.g. us-west-2."
  }
}

variable "enable_dr_replication" {
  description = "Turns on cross-region DR replication: the /bookstore/db-credentials Secrets Manager replica and ECR image replication into var.secondary_region. Off by default -- previously this was silently gated on secondary_region being non-empty, which it always was by default, so both replicas were created on every apply whether DR was wanted or not. See docs/TROUBLESHOOTING.md OBS-049."
  type        = bool
  default     = false
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

variable "dr_kms_key_id" {
  description = "CMK ARN in var.secondary_region for cross-region RDS backup replication. AWS-managed keys are region-scoped and cannot replicate cross-region. Leave empty to skip replication (demo default)."
  type        = string
  default     = ""

  validation {
    condition     = var.dr_kms_key_id == "" || can(regex("^arn:aws:kms:[a-z0-9-]+:\\d{12}:key/.+$", var.dr_kms_key_id))
    error_message = "dr_kms_key_id must be empty or a valid KMS key ARN, e.g. arn:aws:kms:us-west-2:123456789012:key/abcd-1234."
  }
}

variable "monitoring_admin_cidr" {
  description = "CIDR blocks allowed to reach Grafana (3000) and Prometheus (9090) on the monitoring EC2. Default allows all — restrict to your IP in production."
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = alltrue([for c in var.monitoring_admin_cidr : can(cidrhost(c, 0))])
    error_message = "monitoring_admin_cidr must be a list of valid CIDR blocks, e.g. [\"203.0.113.0/24\"]."
  }
}

variable "extra_admin_principal_arns" {
  description = "Additional IAM principal ARNs (teammates, CI/CD roles) to grant EKS cluster-admin, beyond whoever is currently running Terraform (which is always included automatically — see main.tf module.eks)."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.extra_admin_principal_arns : can(regex("^arn:aws:iam::\\d{12}:(user|role)/.+$", a))])
    error_message = "extra_admin_principal_arns must be valid IAM user/role ARNs, e.g. arn:aws:iam::123456789012:role/CIRole."
  }
}

variable "alert_email" {
  description = "Email address Alertmanager sends alert notifications to, via SES SMTP. Also used as the SES sender identity -- SES starts every new account in sandbox mode, which requires both sender and recipient to be verified addresses, so using the same address for both means one verification email to click. Move to a separate verified sender + request SES production access if you outgrow sandbox limits (200 msgs/day, 1/sec). No default -- set ALERT_EMAIL in config.env and run `python scripts/configure.py`, same as domain/account/repo. terraform.tfvars is gitignored and fully regenerated by that script, so don't hand-edit it here directly."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must be a valid email address."
  }
}
