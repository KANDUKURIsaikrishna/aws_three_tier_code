# Prometheus and Alertmanager ship with no built-in authentication of their
# own (unlike Grafana, which gets a real admin password -- see
# grafana-secret.tf). Both are reachable from monitoring_admin_cidr, and
# until this credential existed, anyone in that CIDR could hit either one's
# web UI/API directly -- run arbitrary PromQL against full cluster
# telemetry, or silence firing alerts via Alertmanager's API -- with zero
# login required. Same random-password-in-Secrets-Manager pattern as
# grafana_admin, consumed by modules/monitoring-ec2's user-data script to
# generate a bcrypt-hashed --web.config.file for both, and by Grafana's own
# datasource config so its dashboards keep working (Grafana talks to both
# over the same auth now, not the public internet).
resource "random_password" "monitoring_basic_auth" {
  length  = 24
  special = false
}

resource "aws_secretsmanager_secret" "monitoring_basic_auth" {
  name                    = "/bookstore/monitoring-basic-auth"
  recovery_window_in_days = 0 # 0 = force delete on destroy, no soft-delete window — see TF-012
}

resource "aws_secretsmanager_secret_version" "monitoring_basic_auth" {
  secret_id     = aws_secretsmanager_secret.monitoring_basic_auth.id
  secret_string = random_password.monitoring_basic_auth.result
}
