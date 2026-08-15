# Neither chart has a real functional dependency on the other, or on
# external-secrets/aws-load-balancer-controller (argo-rollouts is a separate
# project from ArgoCD; ArgoCD isn't exposed via ingress or TLS here — no
# ingress.enabled/certificate config is set below). The depends_on chain that
# used to serialize argocd-after-ingress-nginx and argo-rollouts-after-argocd
# was single-node resource-contention avoidance (see TF-001/TF-006 in
# docs/TROUBLESHOOTING.md) from before node_desired_size went to 2 (TF-014).
# Removed to shorten apply time — every Helm chart in this module now
# installs concurrently. If a real apply on this node size starts timing out
# again (TF-001-shaped failures), the fix is to re-add explicit depends_on
# lines, not to keep raising node count indefinitely.

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

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true
  wait             = true
  timeout          = 900

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
