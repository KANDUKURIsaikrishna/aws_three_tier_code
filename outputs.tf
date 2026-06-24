output "vpc_id" {
  description = "ID of the VPC"
  value       = module.network.vpc_id
}

output "rds_endpoint" {
  description = "RDS instance connection endpoint"
  value       = module.rds.rds_endpoint
}

output "rds_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the RDS master password"
  value       = module.rds.master_user_secret_arn
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
