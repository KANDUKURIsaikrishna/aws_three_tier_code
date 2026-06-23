terraform {
  required_providers {
    aws  = { source = "hashicorp/aws" }
    helm = { source = "hashicorp/helm" }
  }
}

# ── EBS CSI driver policy → node role ─────────────────────────────────────────
# Must attach before creating the addon or driver pods stay stuck in CREATING.

resource "aws_iam_role_policy_attachment" "ebs_csi_policy" {
  role       = var.node_role_name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# ── EBS CSI driver (AWS managed addon) ────────────────────────────────────────

resource "aws_eks_addon" "ebs_csi" {
  cluster_name      = var.cluster_name
  addon_name        = "aws-ebs-csi-driver"
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
