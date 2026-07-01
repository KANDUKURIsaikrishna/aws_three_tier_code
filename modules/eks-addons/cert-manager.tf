resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = "v1.14.4"
  namespace        = "cert-manager"
  create_namespace = true
  wait             = true
  timeout          = 600

  set {
    name  = "installCRDs"
    value = "true"
  }
  set {
    name  = "replicaCount"
    value = "1"
  }
}
