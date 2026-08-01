# ── Private Hosted Zone (RDS internal DNS) ─────────────────────────────────────

resource "aws_route53_zone" "rds_private" {
  name = var.rds_private_zone_name
  vpc {
    vpc_id = var.vpc_id
  }
}

resource "aws_route53_record" "rds_endpoint" {
  zone_id = aws_route53_zone.rds_private.zone_id
  name    = var.rds_record_name
  type    = "CNAME"
  ttl     = 100
  records = [var.rds_endpoint]
}

# ── Public Hosted Zone + Active-Passive Failover ───────────────────────────────

resource "aws_route53_zone" "public" {
  name = var.domain

  # Protected on purpose. The 4 NS records this zone gets assigned by AWS
  # were manually copied to the domain's real registrar (GoDaddy) to
  # delegate the domain to Route53 — a one-time, outside-Terraform, manual
  # step. If this zone is ever destroyed and recreated, AWS assigns a
  # DIFFERENT set of 4 nameservers, silently breaking that delegation until
  # someone notices and manually updates the registrar again. prevent_destroy
  # stops that from happening by accident during a routine `terraform
  # destroy` of the rest of the stack (which this project does often during
  # development — see TROUBLESHOOTING.md TF-015/TF-017).
  #
  # Every OTHER resource in this stack (RDS, EKS, records inside this zone,
  # etc.) still destroys/recreates freely — this is scoped to just the zone
  # itself, since that's the only thing whose identity the registrar
  # actually depends on.
  #
  # To intentionally destroy and recreate this zone later (and redo the
  # GoDaddy NS delegation from scratch): remove this lifecycle block first,
  # then `terraform apply` (removing prevent_destroy is itself a plan-time
  # change, not a resource replacement) before running `terraform destroy`.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_route53_health_check" "primary" {
  fqdn              = var.domain
  port              = 443
  type              = "HTTPS"
  resource_path     = "/"
  failure_threshold = 3
  request_interval  = 30

  tags = { Name = "bookstore-primary-health" }
}

# The ingress-nginx LB's Route53 hosted zone ID — an AWS-published,
# region-specific constant (distinct from the zone this module creates).
# Needed to alias the apex domain at the LB: DNS forbids a CNAME at a zone
# apex (the apex needs NS/SOA records too, and CNAME must be the only record
# for its name), and Route53's ALIAS record type is the AWS-specific
# workaround — it behaves like a CNAME but is legal at the apex. Scoped to
# var.aws_region implicitly via this module's (default) provider.
#
# Classic ELB, NOT an NLB — despite this whole project historically calling
# this an "NLB" (docs included), it isn't one. No aws-load-balancer-controller
# is installed (modules/eks-addons has no such helm_release), and
# modules/eks-addons/ingress.tf never sets the
# service.beta.kubernetes.io/aws-load-balancer-type: nlb annotation on
# ingress-nginx's Service. On EKS, a plain `type: LoadBalancer` Service with
# neither of those falls back to the legacy in-tree cloud provider's Classic
# ELB. Confirmed by two real Route53 errors in sequence: first "the alias
# target name does not lie within the target zone" when this used
# aws_lb_hosted_zone_id (load_balancer_type="network") — proving it's not an
# NLB — then that same data source rejecting "classic" outright
# (`expected load_balancer_type to be one of ["application" "network"]`) —
# aws_lb_hosted_zone_id only covers ELBv2 (ALB/NLB), not the classic v1 ELB
# this cluster actually creates. aws_elb_hosted_zone_id is the correct,
# separate data source for that. See TROUBLESHOOTING OBS-010.
data "aws_elb_hosted_zone_id" "ingress_lb" {}

# Direct-to-ingress-LB record — active when CloudFront is disabled.
# primary_alb_dns is auto-discovered within the same apply (root argocd.tf's
# kubernetes_service data source) unless var.primary_alb_dns overrides it.
#
# count deliberately does NOT check `var.primary_alb_dns != ""` — that value
# is now sourced from a data source read gated on module.eks_addons, so it's
# unknown at plan time, and Terraform can't evaluate a count expression against
# an unknown value ("Invalid count argument" at plan). enable_cloudfront alone
# (a plain bool, always known) is what gates this record's existence; the
# upstream null_resource.wait_for_alb_hostname (argocd.tf) already hard-fails
# the apply if the LB hostname never actually shows up, so by the time this
# resource applies, alias.name = var.primary_alb_dns is guaranteed non-empty.
resource "aws_route53_record" "primary" {
  count   = var.enable_cloudfront ? 0 : 1
  zone_id = aws_route53_zone.public.zone_id
  name    = var.domain
  type    = "A"

  alias {
    name                   = var.primary_alb_dns
    zone_id                = data.aws_elb_hosted_zone_id.ingress_lb.id
    evaluate_target_health = true
  }

  failover_routing_policy { type = "PRIMARY" }
  set_identifier  = "primary"
  health_check_id = aws_route53_health_check.primary.id
}

# The actual app-serving hostnames — genuinely missing until OBS-025.
# k8s/base/ingress/ingress.yaml's Ingress rules only match
# bookstore.<domain> (frontend) and api.bookstore.<domain> (backend), never
# the bare apex — nginx's default backend returns 404 for anything else,
# apex included. Every record above this one only ever covered the apex, so
# neither of these two hostnames has ever had a Route53 record in either
# hosted zone this project has used — the site has never actually been
# reachable by name. Same ALIAS pattern as `primary` above (Classic ELB,
# same apex-CNAME-forbidden reasoning doesn't strictly apply here since
# these aren't the zone apex, but ALIAS is still preferred over CNAME so
# Route53 can evaluate target health / avoid the extra CNAME lookup hop),
# no failover/health-check complexity — that's an apex-only concern in this
# design (see the `primary`/`secondary` comments above), not needed for
# these. Not gated on `var.primary_alb_dns != ""` for the same reason
# `primary` above isn't (OBS-008): that value is unknown at plan time.
resource "aws_route53_record" "frontend" {
  zone_id = aws_route53_zone.public.zone_id
  name    = "bookstore.${var.domain}"
  type    = "A"

  alias {
    name                   = var.primary_alb_dns
    zone_id                = data.aws_elb_hosted_zone_id.ingress_lb.id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "api" {
  zone_id = aws_route53_zone.public.zone_id
  name    = "api.bookstore.${var.domain}"
  type    = "A"

  alias {
    name                   = var.primary_alb_dns
    zone_id                = data.aws_elb_hosted_zone_id.ingress_lb.id
    evaluate_target_health = true
  }
}

# Still CNAME, not ALIAS — genuinely fine for now, NOT a bug: this record only
# ever gets created once var.secondary_alb_dns is non-empty (count below), and
# that only happens once a secondary-region EKS cluster + ingress LB actually
# exist, which they don't yet (see ARCHITECTURE.md — DR is backup-level only
# today). When that day comes, this needs the SAME apex-alias treatment as
# `primary` above, but pointed at the secondary region's LB hosted zone ID —
# region-specific and NOT the same value as data.aws_elb_hosted_zone_id.ingress_lb
# above (that one resolves against var.aws_region, the primary region, via
# this module's default provider — and confirm the secondary cluster's ingress
# is the same LB type, classic, before reusing this pattern; don't assume it).
# Wiring a second, secondary-region-scoped provider through this module is
# real work, deliberately deferred until there's an actual secondary LB to
# point at — don't copy today's CNAME pattern for this once secondary_alb_dns
# is real; fix it properly then.
resource "aws_route53_record" "secondary" {
  count   = var.secondary_alb_dns != "" ? 1 : 0
  zone_id = aws_route53_zone.public.zone_id
  name    = var.domain
  type    = "CNAME"
  ttl     = 60
  records = [var.secondary_alb_dns]

  failover_routing_policy { type = "SECONDARY" }
  set_identifier = "secondary"
}

# CloudFront record — active when enable_cloudfront=true.
# Replaces the direct-to-ingress-LB primary record; CloudFront becomes the
# entry point. Same apex-CNAME problem as `primary` above, same ALIAS fix.
# CloudFront's hosted zone ID is a fixed, AWS-wide constant — same value in
# every account, every region
# (https://docs.aws.amazon.com/general/latest/gr/cf_region.html), unlike the
# ingress LB's, which is region-specific and comes from a data source.
resource "aws_route53_record" "primary_cf" {
  count   = var.enable_cloudfront && var.cloudfront_domain != "" ? 1 : 0
  zone_id = aws_route53_zone.public.zone_id
  name    = var.domain
  type    = "A"

  alias {
    name                   = var.cloudfront_domain
    zone_id                = "Z2FDTNDATAQYW2" # CloudFront's fixed hosted zone ID, not region-specific
    evaluate_target_health = false            # CloudFront distributions don't support target health evaluation
  }

  failover_routing_policy { type = "PRIMARY" }
  set_identifier  = "primary-cf"
  health_check_id = aws_route53_health_check.primary.id
}
