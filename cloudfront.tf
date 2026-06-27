# CloudFront ACM cert must be in us-east-1 — uses secondary provider alias.
# Cross-region provider aliases cannot be passed into child modules without
# explicit provider configuration blocks, so these resources live at root.
resource "aws_acm_certificate" "cloudfront" {
  count             = var.enable_cloudfront && var.primary_alb_dns != "" ? 1 : 0
  provider          = aws.secondary
  domain_name       = var.domain
  validation_method = "DNS"

  subject_alternative_names = ["*.${var.domain}"]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_cloudfront_distribution" "frontend" {
  count   = var.enable_cloudfront && var.primary_alb_dns != "" ? 1 : 0
  enabled = true
  aliases = [var.domain, "www.${var.domain}"]
  comment = "bookstore frontend CDN"

  origin {
    domain_name = var.primary_alb_dns
    origin_id   = "nginx-nlb"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "nginx-nlb"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    forwarded_values {
      query_string = true
      headers      = ["Host", "Authorization"]
      cookies { forward = "none" }
    }

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
  }

  ordered_cache_behavior {
    path_pattern           = "/static/*"
    target_origin_id       = "nginx-nlb"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }

    min_ttl     = 86400
    default_ttl = 604800
    max_ttl     = 31536000
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate.cloudfront[0].arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = { Name = "bookstore-cdn" }

  depends_on = [aws_acm_certificate.cloudfront]
}
