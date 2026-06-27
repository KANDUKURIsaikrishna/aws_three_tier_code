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
# primary_alb_dns is set after first apply once the NLB is provisioned:
#   kubectl get svc -n ingress-nginx ingress-nginx-controller \
#     -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
resource "aws_route53_record" "primary" {
  count   = !var.enable_cloudfront && var.primary_alb_dns != "" ? 1 : 0
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
resource "aws_route53_record" "primary_cf" {
  count   = var.enable_cloudfront && var.primary_alb_dns != "" && var.cloudfront_domain != "" ? 1 : 0
  zone_id = aws_route53_zone.public.zone_id
  name    = var.domain
  type    = "CNAME"
  ttl     = 60
  records = [var.cloudfront_domain]

  failover_routing_policy { type = "PRIMARY" }
  set_identifier  = "primary-cf"
  health_check_id = aws_route53_health_check.primary.id
}
