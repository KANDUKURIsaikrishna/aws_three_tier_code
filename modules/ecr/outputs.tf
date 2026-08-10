output "frontend_repo_url" {
  description = "ECR URL for the frontend image"
  value       = aws_ecr_repository.this["${var.prefix}-frontend"].repository_url
}

output "registry_id" {
  description = "AWS account ID owning the registry"
  value       = aws_ecr_repository.this["${var.prefix}-frontend"].registry_id
}

output "repo_urls" {
  description = "Map of short repo name (without prefix) to ECR repository URL — covers frontend and all extra_repos"
  value = {
    for full_name, repo in aws_ecr_repository.this :
    trimprefix(full_name, "${var.prefix}-") => repo.repository_url
  }
}
