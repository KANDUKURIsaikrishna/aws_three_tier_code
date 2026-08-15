data "aws_caller_identity" "eks_addons" {}

data "aws_iam_policy_document" "external_secrets_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_provider_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:external-secrets:external-secrets-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_provider_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "external_secrets" {
  name               = "bookstore-external-secrets"
  assume_role_policy = data.aws_iam_policy_document.external_secrets_trust.json
}

resource "aws_iam_role_policy" "external_secrets" {
  name = "bookstore-external-secrets-secretsmanager"
  role = aws_iam_role.external_secrets.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.eks_addons.account_id}:secret:/bookstore/*"
    }]
  })
}

resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  namespace        = "external-secrets"
  create_namespace = true
  wait             = true
  # Same class of gap as helm_release.argocd in gitops.tf: 600s wasn't
  # enough for a real `terraform destroy` (hit "context deadline exceeded"
  # even though the actual `helm uninstall` had genuinely finished).
  timeout = 900

  set {
    name  = "installCRDs"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "external-secrets-sa"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.external_secrets.arn
  }

  # No real functional dependency on anything else in this module — was
  # serialized against cert-manager/ingress-nginx here only for single-node
  # resource contention, back when the cluster ran one node (see TF main.tf
  # node_desired_size history). Both of those are gone now (cert-manager
  # removed alongside ingress-nginx — see aws-load-balancer-controller.tf);
  # this installs concurrently with whatever remains in this module.
}
