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

  # No real functional dependency on cert-manager (was serialized here only for
  # single-node resource contention — cluster now has 2 nodes, see TF main.tf
  # node_desired_size). Installs concurrently with cert_manager and ingress_nginx.
}
