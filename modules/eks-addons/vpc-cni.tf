# Explicitly manages the vpc-cni addon EKS already creates implicitly at
# cluster creation (resolve_conflicts_on_create = OVERWRITE adopts it instead
# of erroring "already exists"), specifically to turn on network policy
# enforcement. Without this, every NetworkPolicy in k8s/ (default-deny-all +
# per-service allow rules, one set per microservice namespace) is inert --
# nothing in the cluster enforces them, Kubernetes just stores the objects.
# AWS VPC CNI has shipped a built-in network-policy agent since 1.14/EKS 1.25
# -- no separate Calico/Cilium install needed, just this one addon-
# configuration flag.
#
# enableNetworkPolicy is a TOP-LEVEL field, not env.ENABLE_NETWORK_POLICY --
# confirmed live via `aws eks describe-addon-configuration` against the
# current default addon version (v1.22.4-eksbuild.3): the old env-var-style
# toggle from earlier CNI versions was removed from the JSON schema entirely
# (CreateAddon now hard-rejects it: "is not defined in the schema and the
# schema does not allow additional properties"). AWS restructured this at
# some point between when this project was first written and this apply --
# the *setting* it controls hasn't changed, only where it lives in the
# addon's configuration_values JSON. If a future addon version schema change
# breaks this again, re-run `aws eks describe-addon-configuration --addon-name
# vpc-cni --addon-version <version>` and diff the schema before guessing.
resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = var.cluster_name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  configuration_values = jsonencode({
    enableNetworkPolicy = "true"
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
