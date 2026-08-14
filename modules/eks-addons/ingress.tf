resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = "4.9.1"
  namespace        = "ingress-nginx"
  create_namespace = true
  wait             = true
  timeout          = 600

  # 2 replicas, not 1: every request in the app — static assets and every API
  # call — passes through this controller. At replicaCount=1 it was a single
  # point of failure, and its PDB (minAvailable=1, equal to the replica
  # count) made that one pod undrainable — the same anti-pattern OBS-049
  # fixed for the 4 single-replica backend services, missed here because
  # this is a Helm value, not a k8s/ YAML file. maxUnavailable=1 with 2
  # replicas permits exactly one voluntary eviction at a time (node drain,
  # MNG upgrade) while always keeping one pod serving traffic. Runs as pods
  # on the existing fixed node group — no new EC2 instances, no vCPU impact.
  set {
    name  = "controller.replicaCount"
    value = "2"
  }
  set {
    name  = "controller.service.type"
    value = "LoadBalancer"
  }
  set {
    name  = "controller.podDisruptionBudget.maxUnavailable"
    value = "1"
  }

  # No real functional dependency on external_secrets/cert_manager (was
  # serialized only for single-node resource contention, see external-secrets.tf
  # comment). Installs concurrently with them, and with argocd/argo-rollouts too
  # — see gitops.tf.
}

# ── Release the NLB before destroy touches the VPC ────────────────────────────
# controller.service.type=LoadBalancer above makes Kubernetes' cloud-controller
# provision a real AWS NLB as a side effect — Terraform never calls the AWS API
# for it, so it's invisible to `terraform destroy` and blocks subnet deletion
# (DependencyViolation) unless removed first. This automates the manual
# `helm uninstall ingress-nginx` step from the destroy pre-flight checklist.
#
# Best-effort only: requires kubectl + aws CLI on whatever machine runs
# `terraform destroy`. Every command is allowed to fail silently (|| true) so a
# missing binary or already-gone cluster never blocks the rest of the destroy.

data "aws_region" "current" {}

resource "null_resource" "delete_ingress_nginx_lb" {
  triggers = {
    cluster_name = var.cluster_name
    region       = data.aws_region.current.name
  }

  depends_on = [helm_release.ingress_nginx]

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ${self.triggers.region} 2>/dev/null || true
      kubectl delete svc ingress-nginx-controller -n ingress-nginx --wait --timeout=120s --ignore-not-found 2>/dev/null || true
      sleep 30
    EOT
  }
}
