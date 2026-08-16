output "grafana_admin_secret_arn" {
  description = "ARN of Secrets Manager secret holding Grafana admin password (/bookstore/grafana-admin)"
  value       = aws_secretsmanager_secret.grafana_admin.arn
}

output "monitoring_basic_auth_secret_arn" {
  description = "ARN of Secrets Manager secret holding the shared Prometheus/Alertmanager basic-auth password (/bookstore/monitoring-basic-auth)"
  value       = aws_secretsmanager_secret.monitoring_basic_auth.arn
}
