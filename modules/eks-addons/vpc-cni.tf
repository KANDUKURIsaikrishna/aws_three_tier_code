# Explicitly manages the vpc-cni addon EKS already creates implicitly at
# cluster creation (resolve_conflicts_on_create = OVERWRITE adopts it instead
# of erroring "already exists"), specifically to turn on
# ENABLE_NETWORK_POLICY. Without this, every NetworkPolicy in k8s/ (default-
# deny-all + per-service allow rules, one set per microservice namespace) is
# inert -- nothing in the cluster enforces them, Kubernetes just stores the
# objects. AWS VPC CNI has shipped a built-in network-policy agent since
# 1.14/EKS 1.25 -- no separate Calico/Cilium install needed, just this one
# addon-configuration flag.
resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = var.cluster_name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  configuration_values = jsonencode({
    env = {
      ENABLE_NETWORK_POLICY = "true"
    }
  })
}

# HPAs across all 5 microservices + the frontend rely on CPU/memory
# utilization metrics that nothing was providing -- no metrics-server
# anywhere in this project, Terraform or Kubernetes manifests (confirmed by
# grep before adding this). Every HorizontalPodAutoscaler has been showing
# `<unknown>` targets and never actually scaling. AWS ships metrics-server as
# a managed EKS addon, same shape as aws-ebs-csi-driver above -- no Helm
# chart/RBAC to hand-maintain.
resource "aws_eks_addon" "metrics_server" {
  cluster_name                = var.cluster_name
  addon_name                  = "metrics-server"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}
