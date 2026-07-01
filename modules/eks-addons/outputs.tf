output "ingress_nginx_namespace" {
  description = "Namespace where ingress-nginx is installed"
  value       = helm_release.ingress_nginx.namespace
}

output "argocd_namespace" {
  description = "Namespace where ArgoCD is installed"
  value       = helm_release.argocd.namespace
}

output "monitoring_namespace" {
  description = "Namespace for in-cluster monitoring components (kube-state-metrics, node-exporter, promtail)"
  value       = helm_release.kube_state_metrics.namespace
}

output "grafana_admin_secret_arn" {
  description = "ARN of Secrets Manager secret holding Grafana admin password (/bookstore/grafana-admin)"
  value       = aws_secretsmanager_secret.grafana_admin.arn
}
