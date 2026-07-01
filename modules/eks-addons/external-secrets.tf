resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  namespace        = "external-secrets"
  create_namespace = true
  wait             = true
  timeout          = 600

  set {
    name  = "installCRDs"
    value = "true"
  }

  depends_on = [helm_release.cert_manager]
}
