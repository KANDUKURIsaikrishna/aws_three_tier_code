resource "helm_release" "kube_state_metrics" {
  name             = "kube-state-metrics"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-state-metrics"
  namespace        = "monitoring"
  create_namespace = true
  wait             = true
  timeout          = 300

  set {
    name  = "service.type"
    value = "NodePort"
  }
  set {
    name  = "service.nodePort"
    value = "30808"
  }

  depends_on = [helm_release.ingress_nginx]
}

resource "helm_release" "prometheus_node_exporter" {
  name             = "prometheus-node-exporter"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "prometheus-node-exporter"
  namespace        = "monitoring"
  create_namespace = false
  wait             = true
  timeout          = 300

  set {
    name  = "service.type"
    value = "NodePort"
  }
  set {
    name  = "service.nodePort"
    value = "30809"
  }

  depends_on = [helm_release.kube_state_metrics]
}

resource "helm_release" "promtail" {
  name             = "promtail"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "promtail"
  namespace        = "monitoring"
  create_namespace = false
  wait             = true
  timeout          = 300

  set {
    name  = "config.clients[0].url"
    value = "${var.loki_url}/loki/api/v1/push"
  }

  depends_on = [helm_release.prometheus_node_exporter]
}
