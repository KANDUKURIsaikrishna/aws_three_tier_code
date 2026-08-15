# ── ACM Certificate for the ALB (ingress TLS) ──────────────────────────────
# Regional (default provider — wherever the cluster/ALB actually live),
# unlike cloudfront.tf's cert, which AWS hard-requires to be in us-east-1 and
# can't be reused here.
#
# No ARN from this gets injected into any Kubernetes manifest, on purpose:
# the AWS Load Balancer Controller auto-discovers a matching ACM certificate
# by comparing each Ingress's spec.tls[].hosts / spec.rules[].host against
# certificates already issued in the account — see
# k8s/base/ingress/ingress.yaml and k8s/services/api-gateway/base/ingress.yaml,
# neither of which sets an alb.ingress.kubernetes.io/certificate-arn
# annotation. That auto-discovery is what avoids a real chicken-and-egg
# problem: this cert doesn't exist until `terraform apply` creates it, but
# the Ingress YAML is static content in git that ArgoCD deploys on its own
# schedule, entirely decoupled from any Terraform run — there'd be no clean
# moment to write a freshly-created ARN into a checked-in file.
#
# Unlike the CloudFront cert (which requests DNS validation but never
# actually completes it in Terraform), this one does the full loop —
# validation records + aws_acm_certificate_validation — because the ALB
# controller's discovery only matches ISSUED certificates, not pending ones.
resource "aws_acm_certificate" "ingress" {
  domain_name = var.domain
  # "*.${var.domain}" covers exactly one label deep (e.g. bookstore.<domain>,
  # used by k8s/base/ingress/ingress.yaml) -- it does NOT cover
  # api.bookstore.<domain> (two labels deep, used by
  # k8s/services/api-gateway/base/ingress.yaml), a real gap that left the
  # AWS Load Balancer Controller unable to find a matching cert for that
  # Ingress ("no certificate found for host") until this second wildcard
  # was added (OBS-059).
  subject_alternative_names = ["*.${var.domain}", "*.bookstore.${var.domain}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "ingress_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.ingress.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = module.route53.public_zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.record]
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "ingress" {
  certificate_arn         = aws_acm_certificate.ingress.arn
  validation_record_fqdns = [for r in aws_route53_record.ingress_cert_validation : r.fqdn]
}
