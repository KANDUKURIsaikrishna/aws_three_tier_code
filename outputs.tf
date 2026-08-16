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

output "catalog_db_secret_arn" {
  description = "ARN of the Secrets Manager secret at /bookstore/catalog-db-credentials"
  value       = aws_secretsmanager_secret.db_credentials["catalog"].arn
  sensitive   = true
}

output "frontend_repo_url" {
  description = "ECR repository URL for the frontend image"
  value       = module.ecr.frontend_repo_url
}

output "catalog_service_repo_url" {
  description = "ECR repository URL for the catalog-service image"
  value       = module.ecr.repo_urls["catalog-service"]
}

output "user_service_repo_url" {
  description = "ECR repository URL for the user-service image"
  value       = module.ecr.repo_urls["user-service"]
}

output "order_service_repo_url" {
  description = "ECR repository URL for the order-service image"
  value       = module.ecr.repo_urls["order-service"]
}

output "notification_service_repo_url" {
  description = "ECR repository URL for the notification-service image"
  value       = module.ecr.repo_urls["notification-service"]
}

output "api_gateway_repo_url" {
  description = "ECR repository URL for the api-gateway image"
  value       = module.ecr.repo_urls["api-gateway"]
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
  description = "Route53 public hosted zone ID — created once via scripts/init-domain.sh, looked up here"
  value       = module.route53.public_zone_id
}

output "route53_public_name_servers" {
  description = "NS records already set at your domain registrar by scripts/init-domain.sh — informational only"
  value       = module.route53.public_name_servers
}

output "grafana_url" {
  description = "Grafana UI on monitoring EC2 — default user: admin"
  value       = module.monitoring_ec2.grafana_url
}

output "prometheus_url" {
  description = "Prometheus UI on monitoring EC2"
  value       = module.monitoring_ec2.prometheus_url
}

output "loki_url" {
  description = "Loki URL on monitoring EC2 — Promtail in EKS pushes here"
  value       = module.monitoring_ec2.loki_url
}

output "alertmanager_url" {
  description = "Alertmanager UI on monitoring EC2"
  value       = module.monitoring_ec2.alertmanager_url
}

output "monitoring_ssh_private_key" {
  description = "Auto-generated SSH private key for the monitoring EC2 — fetch via: make monitoring-key"
  value       = module.monitoring_ec2.ssh_private_key_pem
  sensitive   = true
}

output "grafana_admin_secret_arn" {
  description = "Secrets Manager secret ARN for Grafana admin password — retrieve: aws secretsmanager get-secret-value --secret-id /bookstore/grafana-admin"
  value       = module.eks_addons.grafana_admin_secret_arn
}

output "cloudfront_domain" {
  description = "CloudFront distribution domain (null when enable_cloudfront=false)"
  value       = try(aws_cloudfront_distribution.frontend[0].domain_name, null)
}

output "user_db_secret_arn" {
  description = "ARN of the Secrets Manager secret at /bookstore/user-db-credentials"
  value       = aws_secretsmanager_secret.db_credentials["user"].arn
  sensitive   = true
}

output "jwt_secret_arn" {
  description = "ARN of the Secrets Manager secret at /bookstore/jwt-secret"
  value       = aws_secretsmanager_secret.jwt_secret.arn
  sensitive   = true
}

output "order_db_secret_arn" {
  description = "ARN of the Secrets Manager secret at /bookstore/order-db-credentials"
  value       = aws_secretsmanager_secret.db_credentials["order"].arn
  sensitive   = true
}

output "notification_db_secret_arn" {
  description = "ARN of the Secrets Manager secret at /bookstore/notification-db-credentials"
  value       = aws_secretsmanager_secret.db_credentials["notification"].arn
  sensitive   = true
}
