resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = "monitoring"
  create_namespace = true
  wait             = true
  timeout          = 600

  set {
    name  = "prometheus.prometheusSpec.replicas"
    value = "1"
  }
  set {
    name  = "alertmanager.enabled"
    value = "true"
  }
  set {
    name  = "alertmanager.alertmanagerSpec.replicas"
    value = "1"
  }
  set {
    name  = "grafana.replicas"
    value = "1"
  }
  set {
    name  = "grafana.persistence.enabled"
    value = "false"
  }
  set {
    name  = "prometheus.prometheusSpec.retention"
    value = "24h"
  }

  set_sensitive {
    name  = "grafana.adminPassword"
    value = random_password.grafana_admin.result
  }

  set {
    name  = "grafana.additionalDataSources[0].name"
    value = "Loki"
  }
  set {
    name  = "grafana.additionalDataSources[0].type"
    value = "loki"
  }
  set {
    name  = "grafana.additionalDataSources[0].url"
    value = "http://loki.monitoring.svc.cluster.local:3100"
  }
  set {
    name  = "grafana.additionalDataSources[0].access"
    value = "proxy"
  }
  set {
    name  = "grafana.additionalDataSources[0].isDefault"
    value = "false"
  }

  depends_on = [aws_secretsmanager_secret_version.grafana_admin]
}

resource "helm_release" "loki" {
  name             = "loki"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "loki-stack"
  namespace        = "monitoring"
  create_namespace = false
  wait             = true
  timeout          = 300

  set {
    name  = "loki.persistence.enabled"
    value = "false"
  }
  set {
    name  = "promtail.enabled"
    value = "true"
  }
  set {
    name  = "grafana.enabled"
    value = "false"
  }

  depends_on = [helm_release.kube_prometheus_stack]
}
