output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "cluster_ca_certificate" {
  description = "Base64-encoded CA certificate for the cluster"
  value       = aws_eks_cluster.this.certificate_authority[0].data
  sensitive   = true
}

output "oidc_provider_arn" {
  description = "ARN of the OIDC provider — used to create IRSA roles"
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "oidc_provider_url" {
  value = aws_iam_openid_connect_provider.eks.url
}

output "node_group_role_arn" {
  value = aws_iam_role.node_group.arn
}

output "node_role_name" {
  description = "IAM role name of the node group (for policy attachments)"
  value       = aws_iam_role.node_group.name
}
