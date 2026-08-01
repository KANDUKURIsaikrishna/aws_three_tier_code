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

# NLB's Route53 hosted zone ID — an AWS-published, region-specific constant
# (distinct from the zone this module creates). Needed to alias the apex
# domain at the NLB: DNS forbids a CNAME at a zone apex (the apex needs
# NS/SOA records too, and CNAME must be the only record for its name), and
# Route53's ALIAS record type is the AWS-specific workaround — it behaves
# like a CNAME but is legal at the apex. Scoped to var.aws_region implicitly
# via this module's (default) provider.
data "aws_lb_hosted_zone_id" "nlb" {
  load_balancer_type = "network"
}

# Direct-to-ALB record — active when CloudFront is disabled.
# primary_alb_dns is auto-discovered within the same apply (root argocd.tf's
# kubernetes_service data source) unless var.primary_alb_dns overrides it.
#
# count deliberately does NOT check `var.primary_alb_dns != ""` — that value
# is now sourced from a data source read gated on module.eks_addons, so it's
# unknown at plan time, and Terraform can't evaluate a count expression against
# an unknown value ("Invalid count argument" at plan). enable_cloudfront alone
# (a plain bool, always known) is what gates this record's existence; the
# upstream null_resource.wait_for_alb_hostname (argocd.tf) already hard-fails
# the apply if the NLB hostname never actually shows up, so by the time this
# resource applies, alias.name = var.primary_alb_dns is guaranteed non-empty.
resource "aws_route53_record" "primary" {
  count   = var.enable_cloudfront ? 0 : 1
  zone_id = aws_route53_zone.public.zone_id
  name    = var.domain
  type    = "A"

  alias {
    name                   = var.primary_alb_dns
    zone_id                = data.aws_lb_hosted_zone_id.nlb.id
    evaluate_target_health = true
  }

  failover_routing_policy { type = "PRIMARY" }
  set_identifier  = "primary"
  health_check_id = aws_route53_health_check.primary.id
}

# Still CNAME, not ALIAS — genuinely fine for now, NOT a bug: this record only
# ever gets created once var.secondary_alb_dns is non-empty (count below), and
# that only happens once a secondary-region EKS cluster + NLB actually exist,
# which they don't yet (see ARCHITECTURE.md — DR is backup-level only today).
# When that day comes, this needs the SAME apex-alias treatment as `primary`
# above, but pointed at the secondary region's NLB hosted zone ID — which is
# region-specific and NOT the same value as data.aws_lb_hosted_zone_id.nlb
# above (that one resolves against var.aws_region, the primary region, via
# this module's default provider). Wiring a second, secondary-region-scoped
# provider through this module is real work, deliberately deferred until
# there's an actual secondary NLB to point at — don't copy today's CNAME
# pattern for this once secondary_alb_dns is real; fix it properly then.
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
# Replaces the direct-to-ALB primary record; CloudFront becomes the entry point.
# Same apex-CNAME problem as `primary` above, same ALIAS fix. CloudFront's
# hosted zone ID is a fixed, AWS-wide constant — same value in every account,
# every region (https://docs.aws.amazon.com/general/latest/gr/cf_region.html),
# unlike the NLB's, which is region-specific and comes from a data source.
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
