# ─────────────────────────────────────────────────────────────────────────────
# ArgoCD bootstrap — Terraform-managed, not manual `kubectl apply`
#
# Previously: DEPLOYMENT.md told you to run
#   kubectl apply -f k8s/argocd/appproject.yaml
#   kubectl apply -f k8s/argocd/application.yaml
#   kubectl apply -f k8s/argocd/applicationset-microservices.yaml
# by hand, once, after eks-addons installed ArgoCD. That's now this file's job.
#
# appproject.yaml genuinely was missed here for a while (application.yaml and
# applicationset-microservices.yaml got wired in, appproject.yaml didn't) --
# invisible on a long-lived cluster where the AppProject, once created, just
# sits there; it only surfaced as a real outage on the next from-scratch
# `terraform destroy` + `apply` cycle, when the Application/ApplicationSet
# came up referencing a project that no longer existed (OBS-058).
#
# Applies the existing YAML files as-is (kubectl_manifest takes a raw YAML
# body — no need to re-express them as HCL objects, so the files in k8s/argocd/
# stay the single source of truth and these resources can't drift from them).
# The AppProject must exist before the Application/ApplicationSet that
# reference it, hence the explicit depends_on below (ArgoCD itself validates
# this at admission — an Application naming a nonexistent project is rejected).
# ─────────────────────────────────────────────────────────────────────────────

resource "kubectl_manifest" "argocd_appproject" {
  yaml_body = file("${path.module}/k8s/argocd/appproject.yaml")

  depends_on = [module.eks_addons]
}

resource "kubectl_manifest" "argocd_application" {
  yaml_body = file("${path.module}/k8s/argocd/application.yaml")

  depends_on = [module.eks_addons, kubectl_manifest.argocd_appproject]
}

resource "kubectl_manifest" "argocd_applicationset_microservices" {
  yaml_body = file("${path.module}/k8s/argocd/applicationset-microservices.yaml")

  depends_on = [module.eks_addons, kubectl_manifest.argocd_appproject]
}

# ─────────────────────────────────────────────────────────────────────────────
# Auto-discover the ALB hostname
#
# Previously: DEPLOYMENT.md needed a SECOND `terraform apply` — Terraform can't
# create the Route53 record pointing at the load balancer until it exists,
# and it doesn't exist until after this same apply's eks-addons stage
# finishes, so you had to run apply, check the hostname by hand, paste it
# into terraform.tfvars, then apply again.
#
# This got a real sequencing wrinkle when ingress-nginx (which provisioned
# its load balancer directly via a Terraform-managed helm_release with
# wait=true) was replaced by the AWS Load Balancer Controller (which
# provisions the ALB by reconciling an Ingress object) — see
# modules/eks-addons/aws-load-balancer-controller.tf. That Ingress object
# isn't created by Terraform at all; it's deployed by ArgoCD, asynchronously,
# on its own reconcile loop, after kubectl_manifest.argocd_application merely
# creates the ArgoCD Application pointing at it. `kubectl wait` needs its
# target resource to already EXIST or it fails immediately (not a graceful
# timeout) — so this now polls for the Ingress object's existence first,
# THEN waits for the controller to populate its hostname, instead of the
# single-stage wait that was enough when the load balancer came from a
# Helm chart Terraform installed directly.
# ─────────────────────────────────────────────────────────────────────────────

resource "null_resource" "wait_for_alb_hostname" {
  triggers = {
    # Re-run only when the Application manifest actually changes, not on
    # every apply. A timestamp() trigger here forced a destroy+recreate of
    # this resource on every single `terraform apply`, which cascaded into
    # spurious "known after apply" diffs on the 3 Route53 alias records that
    # read the ALB hostname through this resource's data source below.
    argocd_application_id = kubectl_manifest.argocd_application.id
  }

  depends_on = [module.eks_addons, kubectl_manifest.argocd_application]

  provisioner "local-exec" {
    command = <<-EOT
      aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region} >/dev/null

      # Stage 1: wait for ArgoCD to have actually synced the Ingress object
      # into existence -- up to 5 minutes, generous since automated sync on
      # a brand-new Application typically starts within seconds, not a full
      # 3-minute poll cycle, but this is a safety margin, not the expected path.
      for i in $(seq 1 60); do
        kubectl get ingress bookstore-ingress -n bookstore >/dev/null 2>&1 && break
        sleep 5
      done

      # Stage 2: wait for the AWS Load Balancer Controller to finish
      # provisioning the real ALB and populate the Ingress's status.
      kubectl wait --for=jsonpath='{.status.loadBalancer.ingress[0].hostname}' \
        ingress/bookstore-ingress -n bookstore --timeout=240s
    EOT
  }
}

data "kubernetes_ingress_v1" "bookstore" {
  metadata {
    name      = "bookstore-ingress"
    namespace = "bookstore"
  }

  depends_on = [null_resource.wait_for_alb_hostname]
}

locals {
  # var.primary_alb_dns stays as a manual override (e.g. pointing at a
  # different or manually-managed LB) — auto-discovery is just the default.
  # Reading the frontend's Ingress specifically, not the gateway's -- both
  # share one ALB via the same alb.ingress.kubernetes.io/group.name, so
  # either object's status reports the same hostname; this one was picked
  # arbitrarily as "the" one to watch.
  discovered_alb_dns = try(data.kubernetes_ingress_v1.bookstore.status[0].load_balancer[0].ingress[0].hostname, "")
  primary_alb_dns    = var.primary_alb_dns != "" ? var.primary_alb_dns : local.discovered_alb_dns
}
