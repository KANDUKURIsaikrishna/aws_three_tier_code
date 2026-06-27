provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "bookstore"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

provider "aws" {
  alias  = "secondary"
  region = var.secondary_region

  default_tags {
    tags = {
      Project     = "bookstore"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
    }
  }
}

# ── Networking ─────────────────────────────────────────────────────────────────

module "network" {
  source   = "./modules/network"
  vpc_cidr = "170.20.0.0/16"

  public_subnets = [
    { cidr = "170.20.1.0/24", az = "us-west-1a" },
    { cidr = "170.20.2.0/24", az = "us-west-1c" },
  ]

  private_subnets = [
    { cidr = "170.20.3.0/24", az = "us-west-1a" },  # [0] EKS nodes
    { cidr = "170.20.4.0/24", az = "us-west-1c" },  # [1] EKS nodes
    { cidr = "170.20.5.0/24", az = "us-west-1a" },  # [2] EKS nodes
    { cidr = "170.20.6.0/24", az = "us-west-1c" },  # [3] EKS nodes
    { cidr = "170.20.7.0/24", az = "us-west-1a" },  # [4] RDS
    { cidr = "170.20.8.0/24", az = "us-west-1c" },  # [5] RDS
  ]
}

# ── Security Groups ────────────────────────────────────────────────────────────

module "security_groups" {
  source = "./modules/security"
  vpc_id = module.network.vpc_id
  prefix = "bookstore"
}

# ── ACM Certificate ────────────────────────────────────────────────────────────

module "acm" {
  source      = "./modules/acm"
  domain_name = var.domain
  san_names   = ["*.${var.domain}"]
}

# ── RDS ────────────────────────────────────────────────────────────────────────

module "rds" {
  source               = "./modules/rds"
  db_identifier        = "bookstore-db"
  db_engine            = "mysql"
  db_engine_version    = "8.0"
  db_instance_class    = "db.t3.micro"
  db_allocated_storage = 25
  max_allocated_storage = 100
  db_name              = "test"
  db_username          = "admin"
  db_security_group_id = module.security_groups.rds_sg_id
  db_subnet_ids = [
    module.network.private_subnet_ids[4],
    module.network.private_subnet_ids[5],
  ]
  multi_az                = true
  backup_retention_period = 7
  deletion_protection     = true
  secondary_region        = var.secondary_region
}

# ── RDS Cross-Region Backup Replication ───────────────────────────────────────
# Replicates automated backups to secondary region.
# In a DR event: restore from backup in secondary region, promote, update DB_HOST.

resource "aws_db_instance_automated_backups_replication" "secondary" {
  provider                    = aws.secondary
  source_db_instance_arn      = module.rds.rds_instance_arn
  retention_period            = 7
}

# ── Route 53 (private zone for RDS internal DNS resolution) ───────────────────

module "route53" {
  source       = "./modules/route53"
  vpc_id       = module.network.vpc_id
  rds_endpoint = module.rds.rds_endpoint
}

# ── ECR ────────────────────────────────────────────────────────────────────────

module "ecr" {
  source                = "./modules/ecr"
  prefix                = "bookstore"
  image_retention_count = 10
}

# ── ECR Cross-Region Replication ──────────────────────────────────────────────
# Replicates all ECR images to secondary region so secondary EKS can pull them.

resource "aws_ecr_replication_configuration" "secondary" {
  replication_configuration {
    rule {
      destination {
        region      = var.secondary_region
        registry_id = module.ecr.registry_id
      }
      repository_filter {
        filter      = "bookstore"
        filter_type = "PREFIX_MATCH"
      }
    }
  }

  depends_on = [module.ecr]
}

# ── Route53 Public Zone + Active-Passive Failover ─────────────────────────────

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

# primary_alb_dns: get after first apply via:
#   kubectl get svc -n ingress-nginx ingress-nginx-controller \
#     -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
resource "aws_route53_record" "primary" {
  count   = var.primary_alb_dns != "" ? 1 : 0
  zone_id = aws_route53_zone.public.zone_id
  name    = var.domain
  type    = "CNAME"
  ttl     = 60
  records = [var.primary_alb_dns]

  failover_routing_policy {
    type = "PRIMARY"
  }

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

  failover_routing_policy {
    type = "SECONDARY"
  }

  set_identifier = "secondary"
}

# ── EKS ────────────────────────────────────────────────────────────────────────

module "eks" {
  source          = "./modules/eks"
  cluster_name    = "bookstore-eks"
  cluster_version = "1.31"
  prefix          = "bookstore"
  vpc_id          = module.network.vpc_id

  subnet_ids = [
    module.network.private_subnet_ids[0],
    module.network.private_subnet_ids[1],
    module.network.private_subnet_ids[2],
    module.network.private_subnet_ids[3],
  ]

  node_instance_type = "t3.medium"  # smallest that fits all add-ons (4 GB RAM)
  node_min_size      = 1
  node_max_size      = 2            # tech demo cap — raise to 4 for production
  node_desired_size  = 1            # single node at rest; HPA scales pods, CA scales nodes
}

# ── EKS Add-ons (cert-manager, ESO, ingress-nginx, ArgoCD, Prometheus, Rollouts) ──

module "eks_addons" {
  source = "./modules/eks-addons"

  cluster_name      = module.eks.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
  node_role_name    = module.eks.node_role_name

  depends_on = [module.eks]
}

# ── CloudFront CDN (optional — set enable_cloudfront=true after first apply) ──
# CloudFront ACM cert MUST be in us-east-1 — uses the secondary provider alias.

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

  # Cache static assets at edge
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

# When CloudFront is enabled, Route53 primary record points to CF distribution
resource "aws_route53_record" "primary_cf" {
  count   = var.enable_cloudfront && var.primary_alb_dns != "" ? 1 : 0
  zone_id = aws_route53_zone.public.zone_id
  name    = var.domain
  type    = "CNAME"
  ttl     = 60
  records = [aws_cloudfront_distribution.frontend[0].domain_name]

  failover_routing_policy { type = "PRIMARY" }
  set_identifier  = "primary-cf"
  health_check_id = aws_route53_health_check.primary.id
}
