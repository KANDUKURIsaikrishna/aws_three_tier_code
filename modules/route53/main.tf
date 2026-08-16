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

# Looked up, not created: the zone's 4 NS values are fixed the moment it's
# created and never change again, but the domain registrar (GoDaddy) only
# points at those values after a manual, outside-Terraform step. A
# `resource "aws_route53_zone"` here would get destroyed and recreated with
# BRAND NEW nameservers on every `terraform destroy` + fresh `apply`,
# breaking the registrar delegation every single cycle and forcing that
# manual step to be redone each time (see TROUBLESHOOTING.md OBS-058).
# Run `scripts/init-domain.sh` once per domain, ever, to create this zone
# and do the registrar handoff — after that, every apply/destroy cycle just
# reads it here and never touches it.
data "aws_route53_zone" "public" {
  name         = var.domain
  private_zone = false
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
# An Application Load Balancer now, provisioned by the AWS Load Balancer
# Controller reconciling an Ingress object (see
# modules/eks-addons/aws-load-balancer-controller.tf) -- the third distinct
# load balancer type this one data source has had to track, worth knowing
# the whole history of if this ever needs touching again:
#   1. Classic ELB (accidental — ingress-nginx's default, `aws_elb_hosted_zone_id`)
#   2. NLB (`aws_lb_hosted_zone_id { load_balancer_type = "network" }`,
#      via a Service annotation on ingress-nginx — coded but never applied
#      before ingress-nginx itself was replaced, see TROUBLESHOOTING.md OBS-056/057)
#   3. ALB (this one — ingress-nginx retired outright, replaced with the AWS
#      Load Balancer Controller per AWS's own official migration guidance)
# `aws_lb_hosted_zone_id` covers ELBv2 (ALB/NLB) specifically;
# `load_balancer_type = "application"` selects the ALB variant of its
# constant (NLB's and Classic's both differ). Using the wrong one of the
# three for whatever the cluster is actually provisioning is exactly what
# broke this twice already, before it was ever even NLB — check
# `aws elbv2 describe-load-balancers` against the real, live load balancer
# before ever changing this again, don't assume from a doc.
data "aws_lb_hosted_zone_id" "ingress_lb" {
  load_balancer_type = "application"
}

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
  zone_id = data.aws_route53_zone.public.zone_id
  name    = var.domain
  type    = "A"

  alias {
    name                   = var.primary_alb_dns
    zone_id                = data.aws_lb_hosted_zone_id.ingress_lb.id
    evaluate_target_health = true
  }

  failover_routing_policy { type = "PRIMARY" }
  set_identifier  = "primary"
  health_check_id = aws_route53_health_check.primary.id
}

# The actual app-serving hostnames — genuinely missing until OBS-025.
# k8s/base/ingress/ingress.yaml's Ingress rules only match
# bookstore.<domain> (frontend) and api.bookstore.<domain> (backend), never
# the bare apex — the ALB's default rule returns 404 for anything that
# doesn't match a configured host/path, apex included. Every record above
# this one only ever covered the apex, so neither of these two hostnames
# has ever had a Route53 record in either hosted zone this project has
# used — the site has never actually been reachable by name. Same ALIAS
# pattern as `primary` above (ALB,
# same apex-CNAME-forbidden reasoning doesn't strictly apply here since
# these aren't the zone apex, but ALIAS is still preferred over CNAME so
# Route53 can evaluate target health / avoid the extra CNAME lookup hop),
# no failover/health-check complexity — that's an apex-only concern in this
# design (see the `primary`/`secondary` comments above), not needed for
# these. Not gated on `var.primary_alb_dns != ""` for the same reason
# `primary` above isn't (OBS-008): that value is unknown at plan time.
resource "aws_route53_record" "frontend" {
  zone_id = data.aws_route53_zone.public.zone_id
  name    = "bookstore.${var.domain}"
  type    = "A"

  alias {
    name                   = var.primary_alb_dns
    zone_id                = data.aws_lb_hosted_zone_id.ingress_lb.id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "api" {
  zone_id = data.aws_route53_zone.public.zone_id
  name    = "api.bookstore.${var.domain}"
  type    = "A"

  alias {
    name                   = var.primary_alb_dns
    zone_id                = data.aws_lb_hosted_zone_id.ingress_lb.id
    evaluate_target_health = true
  }
}

# Still CNAME, not ALIAS — genuinely fine for now, NOT a bug: this record only
# ever gets created once var.secondary_alb_dns is non-empty (count below), and
# that only happens once a secondary-region EKS cluster + ingress LB actually
# exist, which they don't yet (see ARCHITECTURE.md — DR is backup-level only
# today). When that day comes, this needs the SAME apex-alias treatment as
# `primary` above, but pointed at the secondary region's LB hosted zone ID —
# region-specific and NOT the same value as data.aws_lb_hosted_zone_id.ingress_lb
# above (that one resolves against var.aws_region, the primary region, via
# this module's default provider — and confirm the secondary cluster's ingress
# is the same LB type, ALB, before reusing this pattern; don't assume it).
# Wiring a second, secondary-region-scoped provider through this module is
# real work, deliberately deferred until there's an actual secondary LB to
# point at — don't copy today's CNAME pattern for this once secondary_alb_dns
# is real; fix it properly then.
resource "aws_route53_record" "secondary" {
  count   = var.secondary_alb_dns != "" ? 1 : 0
  zone_id = data.aws_route53_zone.public.zone_id
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
  zone_id = data.aws_route53_zone.public.zone_id
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
