output "vpc_id" {
  description = "ID of the VPC"
  value       = module.network.vpc_id
}

output "rds_endpoint" {
  description = "RDS instance connection endpoint"
  value       = module.rds.rds_endpoint
}

output "rds_secret_arn" {
  description = "ARN of the Secrets Manager secret at /bookstore/db-credentials (DB_USERNAME, DB_PASSWORD, DB_HOST)"
  value       = module.rds.db_credentials_secret_arn
  sensitive   = true
}

output "frontend_repo_url" {
  description = "ECR repository URL for the frontend image"
  value       = module.ecr.frontend_repo_url
}

output "backend_repo_url" {
  description = "ECR repository URL for the backend image"
  value       = module.ecr.backend_repo_url
}

output "eks_cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "eks_oidc_provider_arn" {
  description = "ARN of the EKS OIDC provider — used to create IRSA roles"
  value       = module.eks.oidc_provider_arn
}

output "github_oidc_role_arn" {
  description = "ARN of the IAM role assumed by GitHub Actions via OIDC"
  value       = aws_iam_role.github_oidc.arn
}

output "route53_public_zone_id" {
  description = "Route53 public hosted zone ID — add NS records at registrar after first apply"
  value       = module.route53.public_zone_id
}

output "route53_public_name_servers" {
  description = "NS records to set at your domain registrar for Route53 to take authority"
  value       = module.route53.public_name_servers
}

output "loki_service_url" {
  description = "Loki service URL — add as data source in Grafana"
  value       = module.eks_addons.loki_service
}

output "grafana_admin_secret_arn" {
  description = "Secrets Manager secret ARN for Grafana admin password — retrieve: aws secretsmanager get-secret-value --secret-id /bookstore/grafana-admin"
  value       = module.eks_addons.grafana_admin_secret_arn
}

output "cloudfront_domain" {
  description = "CloudFront distribution domain (null when enable_cloudfront=false)"
  value       = try(aws_cloudfront_distribution.frontend[0].domain_name, null)
}
