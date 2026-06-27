output "ingress_nginx_namespace" {
  description = "Namespace where ingress-nginx is installed"
  value       = helm_release.ingress_nginx.namespace
}

output "argocd_namespace" {
  description = "Namespace where ArgoCD is installed"
  value       = helm_release.argocd.namespace
}

output "monitoring_namespace" {
  description = "Namespace where Prometheus, Grafana, and Loki are installed"
  value       = helm_release.kube_prometheus_stack.namespace
}

output "loki_service" {
  description = "Loki service URL for Grafana data source config"
  value       = "http://loki.${helm_release.loki.namespace}.svc.cluster.local:3100"
}

output "grafana_admin_secret_arn" {
  description = "ARN of Secrets Manager secret holding Grafana admin password (/bookstore/grafana-admin)"
  value       = aws_secretsmanager_secret.grafana_admin.arn
}
