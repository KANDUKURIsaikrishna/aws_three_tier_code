output "frontend_repo_url" {
  description = "ECR URL for the frontend image"
  value       = aws_ecr_repository.this["${var.prefix}-frontend"].repository_url
}

output "backend_repo_url" {
  description = "ECR URL for the backend image"
  value       = aws_ecr_repository.this["${var.prefix}-backend"].repository_url
}

output "registry_id" {
  description = "AWS account ID owning the registry"
  value       = aws_ecr_repository.this["${var.prefix}-frontend"].registry_id
}
