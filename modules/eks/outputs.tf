output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = aws_eks_cluster.this.endpoint
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
  description = "URL of the OIDC provider"
  value       = aws_iam_openid_connect_provider.eks.url
}

output "node_group_role_arn" {
  description = "ARN of the node group IAM role"
  value       = aws_iam_role.node_group.arn
}

output "node_role_name" {
  description = "IAM role name of the EKS node group — passed to eks-addons for policy attachment"
  value       = aws_iam_role.node_group.name
}

output "cluster_security_group_id" {
  description = "Auto-created EKS cluster security group — applied to all nodes; monitoring EC2 gets inbound rules here"
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}
