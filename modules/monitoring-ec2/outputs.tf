output "loki_url" {
  description = "Loki base URL — used by Promtail in EKS to push logs"
  value       = "http://${aws_eip_association.monitoring.public_ip}:3100"
}

output "grafana_url" {
  description = "Grafana UI URL"
  value       = "http://${aws_eip_association.monitoring.public_ip}:3000"
}

output "prometheus_url" {
  description = "Prometheus UI URL"
  value       = "http://${aws_eip_association.monitoring.public_ip}:9090"
}

output "alertmanager_url" {
  description = "Alertmanager UI URL"
  value       = "http://${aws_eip_association.monitoring.public_ip}:9093"
}

output "instance_public_ip" {
  description = "Public IP of the monitoring EC2 instance (Elastic IP)"
  value       = aws_eip_association.monitoring.public_ip
}

output "ssh_private_key_pem" {
  description = "Auto-generated SSH private key for the monitoring EC2 (user: ubuntu) — see Makefile's monitoring-key target"
  value       = tls_private_key.monitoring_ssh.private_key_pem
  sensitive   = true
}
