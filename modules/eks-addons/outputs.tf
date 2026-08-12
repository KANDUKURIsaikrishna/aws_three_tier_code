output "grafana_admin_secret_arn" {
  description = "ARN of Secrets Manager secret holding Grafana admin password (/bookstore/grafana-admin)"
  value       = aws_secretsmanager_secret.grafana_admin.arn
}
