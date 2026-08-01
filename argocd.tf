# ─────────────────────────────────────────────────────────────────────────────
# ArgoCD bootstrap — Terraform-managed, not manual `kubectl apply`
#
# Previously: DEPLOYMENT.md told you to run
#   kubectl apply -f k8s/argocd/application.yaml
#   kubectl apply -f k8s/argocd/applicationset-microservices.yaml
# by hand, once, after eks-addons installed ArgoCD. That's now this file's job.
#
# Applies the existing YAML files as-is (kubectl_manifest takes a raw YAML
# body — no need to re-express them as HCL objects, so the files in k8s/argocd/
# stay the single source of truth and these resources can't drift from them).
# ─────────────────────────────────────────────────────────────────────────────

resource "kubectl_manifest" "argocd_application" {
  yaml_body = file("${path.module}/k8s/argocd/application.yaml")

  depends_on = [module.eks_addons]
}

resource "kubectl_manifest" "argocd_applicationset_microservices" {
  yaml_body = file("${path.module}/k8s/argocd/applicationset-microservices.yaml")

  depends_on = [module.eks_addons]
}

# ─────────────────────────────────────────────────────────────────────────────
# Auto-discover the ingress-nginx NLB hostname
#
# Previously: DEPLOYMENT.md needed a SECOND `terraform apply` — Terraform can't
# create the Route53 record pointing at the NLB until the NLB exists, and the
# NLB doesn't exist until after this same apply's eks-addons stage finishes, so
# you had to run apply, `kubectl get svc ...` by hand, paste the hostname into
# terraform.tfvars, then apply again.
#
# helm_release's `wait = true` only waits for ingress-nginx's pods to become
# Ready — it does NOT wait for the AWS cloud-controller to finish provisioning
# the NLB and populate the Service's `status.loadBalancer.ingress[0].hostname`,
# which can lag another 1-3 minutes behind pod readiness. The null_resource
# below polls for that specifically, so the data source after it doesn't race
# an empty hostname on a fresh cluster.
# ─────────────────────────────────────────────────────────────────────────────

resource "null_resource" "wait_for_alb_hostname" {
  triggers = {
    always_run = timestamp() # re-checked every apply — cheap no-op once the hostname already exists
  }

  depends_on = [module.eks_addons]

  provisioner "local-exec" {
    command = <<-EOT
      aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region} >/dev/null
      kubectl wait --for=jsonpath='{.status.loadBalancer.ingress[0].hostname}' \
        svc/ingress-nginx-controller -n ingress-nginx --timeout=180s
    EOT
  }
}

data "kubernetes_service" "ingress_nginx" {
  metadata {
    name      = "ingress-nginx-controller"
    namespace = "ingress-nginx"
  }

  depends_on = [null_resource.wait_for_alb_hostname]
}

locals {
  # var.primary_alb_dns stays as a manual override (e.g. pointing at a
  # different or manually-managed LB) — auto-discovery is just the default.
  discovered_alb_dns = try(data.kubernetes_service.ingress_nginx.status[0].load_balancer[0].ingress[0].hostname, "")
  primary_alb_dns    = var.primary_alb_dns != "" ? var.primary_alb_dns : local.discovered_alb_dns
}
