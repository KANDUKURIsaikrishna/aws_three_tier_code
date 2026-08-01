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
# resource applies, records = [var.primary_alb_dns] is guaranteed non-empty.
resource "aws_route53_record" "primary" {
  count   = var.enable_cloudfront ? 0 : 1
  zone_id = aws_route53_zone.public.zone_id
  name    = var.domain
  type    = "CNAME"
  ttl     = 60
  records = [var.primary_alb_dns]

  failover_routing_policy { type = "PRIMARY" }
  set_identifier  = "primary"
  health_check_id = aws_route53_health_check.primary.id
}

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
# Same reasoning as aws_route53_record.primary above: no `primary_alb_dns != ""`
# in count — that value can be unknown at plan time now. cloudfront_domain is
# what this record actually uses, so that's the only real gate needed.
resource "aws_route53_record" "primary_cf" {
  count   = var.enable_cloudfront && var.cloudfront_domain != "" ? 1 : 0
  zone_id = aws_route53_zone.public.zone_id
  name    = var.domain
  type    = "CNAME"
  ttl     = 60
  records = [var.cloudfront_domain]

  failover_routing_policy { type = "PRIMARY" }
  set_identifier  = "primary-cf"
  health_check_id = aws_route53_health_check.primary.id
}
