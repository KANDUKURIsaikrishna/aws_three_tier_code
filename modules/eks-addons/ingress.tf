resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = "4.9.1"
  namespace        = "ingress-nginx"
  create_namespace = true
  wait             = true
  timeout          = 600

  set {
    name  = "controller.replicaCount"
    value = "1"
  }
  set {
    name  = "controller.service.type"
    value = "LoadBalancer"
  }

  depends_on = [helm_release.external_secrets]
}
