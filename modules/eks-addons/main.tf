terraform {
  required_providers {
    aws    = { source = "hashicorp/aws",    version = "~> 5.0" }
    helm   = { source = "hashicorp/helm",   version = "~> 2.0" }
    random = { source = "hashicorp/random", version = "~> 3.0" }
  }
}

resource "random_password" "grafana_admin" {
  length  = 24
  special = false   # Grafana helm value rejects some special chars in JSON
}

resource "aws_secretsmanager_secret" "grafana_admin" {
  name                    = "/bookstore/grafana-admin"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "grafana_admin" {
  secret_id     = aws_secretsmanager_secret.grafana_admin.id
  secret_string = random_password.grafana_admin.result
}

# ── EBS CSI driver — policy must exist before the addon or pods stay stuck ─────

resource "aws_iam_role_policy_attachment" "ebs_csi_policy" {
  role       = var.node_role_name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = var.cluster_name
  addon_name                  = "aws-ebs-csi-driver"
  resolve_conflicts_on_create = "OVERWRITE"

  depends_on = [aws_iam_role_policy_attachment.ebs_csi_policy]
}

# ── cert-manager ──────────────────────────────────────────────────────────────

resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = "v1.14.4"
  namespace        = "cert-manager"
  create_namespace = true
  wait             = true
  timeout          = 300

  set {
    name  = "installCRDs"
    value = "true"
  }
  set {
    name  = "replicaCount"
    value = "1"
  }
}

# ── External Secrets Operator ─────────────────────────────────────────────────

resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  namespace        = "external-secrets"
  create_namespace = true
  wait             = true
  timeout          = 300

  set {
    name  = "installCRDs"
    value = "true"
  }
}

# ── ingress-nginx ─────────────────────────────────────────────────────────────

resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = "4.9.1"
  namespace        = "ingress-nginx"
  create_namespace = true
  wait             = true
  timeout          = 300

  set {
    name  = "controller.replicaCount"
    value = "1"
  }
  set {
    name  = "controller.service.type"
    value = "LoadBalancer"
  }
}

# ── kube-prometheus-stack (Prometheus + Grafana) ──────────────────────────────

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

  # Loki data source — auto-provisioned so logs appear in Grafana on first login
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

# ── Loki (log aggregation) ────────────────────────────────────────────────────

resource "helm_release" "loki" {
  name             = "loki"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "loki-stack"
  namespace        = "monitoring"
  create_namespace = false   # monitoring namespace created by kube-prometheus-stack
  wait             = true
  timeout          = 300

  set {
    name  = "loki.persistence.enabled"
    value = "false"   # demo: no PVC for Loki
  }
  set {
    name  = "promtail.enabled"
    value = "true"
  }
  set {
    name  = "grafana.enabled"
    value = "false"   # use Grafana from kube-prometheus-stack
  }

  depends_on = [helm_release.kube_prometheus_stack]
}

# ── Argo Rollouts ─────────────────────────────────────────────────────────────

resource "helm_release" "argo_rollouts" {
  name             = "argo-rollouts"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-rollouts"
  namespace        = "argo-rollouts"
  create_namespace = true
  wait             = true
  timeout          = 300

  set {
    name  = "controller.replicas"
    value = "1"
  }
  set {
    name  = "dashboard.enabled"
    value = "false"
  }
}

# ── ArgoCD ────────────────────────────────────────────────────────────────────

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true
  wait             = true
  timeout          = 600

  set {
    name  = "server.replicas"
    value = "1"
  }
  set {
    name  = "repoServer.replicas"
    value = "1"
  }
  set {
    name  = "redis-ha.enabled"
    value = "false"
  }
  set {
    name  = "controller.replicas"
    value = "1"
  }
}
