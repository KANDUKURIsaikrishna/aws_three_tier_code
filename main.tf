# ── Networking ─────────────────────────────────────────────────────────────────

module "network" {
  source          = "./modules/network"
  vpc_cidr        = local.vpc_cidr
  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets
}

# ── Security Groups ────────────────────────────────────────────────────────────

module "security_groups" {
  source = "./modules/security"
  vpc_id = module.network.vpc_id
  prefix = "bookstore"
}

# ── ACM Certificate (us-west-1 — used by ingress-nginx) ───────────────────────

module "acm" {
  source      = "./modules/acm"
  domain_name = var.domain
  san_names   = ["*.${var.domain}"]
}

# ── RDS ────────────────────────────────────────────────────────────────────────

module "rds" {
  source                = "./modules/rds"
  db_identifier         = "bookstore-db"
  db_engine             = "mysql"
  db_engine_version     = "8.0"
  db_instance_class     = "db.t3.micro"
  db_allocated_storage  = 25
  max_allocated_storage = 100
  db_name               = "test"
  db_username           = "admin"
  db_security_group_id  = module.security_groups.rds_sg_id
  db_subnet_ids = [
    module.network.private_subnet_ids[4],
    module.network.private_subnet_ids[5],
  ]
  multi_az                = true
  backup_retention_period = 7
  deletion_protection     = true
  skip_final_snapshot     = false
  secondary_region        = var.secondary_region
}

# ── Route 53 ──────────────────────────────────────────────────────────────────
# Private zone for in-cluster RDS DNS + public zone with active-passive failover.

module "route53" {
  source            = "./modules/route53"
  vpc_id            = module.network.vpc_id
  rds_endpoint      = module.rds.rds_endpoint
  domain            = var.domain
  primary_alb_dns   = var.primary_alb_dns
  secondary_alb_dns = var.secondary_alb_dns
  enable_cloudfront = var.enable_cloudfront
  cloudfront_domain = try(aws_cloudfront_distribution.frontend[0].domain_name, "")
}

# ── ECR ────────────────────────────────────────────────────────────────────────

module "ecr" {
  source                = "./modules/ecr"
  prefix                = "bookstore"
  image_retention_count = 10
  secondary_region      = var.secondary_region
}

# ── EKS ────────────────────────────────────────────────────────────────────────

module "eks" {
  source             = "./modules/eks"
  cluster_name       = "bookstore-eks"
  cluster_version    = "1.31"
  prefix             = "bookstore"
  vpc_id             = module.network.vpc_id
  subnet_ids = [
    module.network.private_subnet_ids[0],
    module.network.private_subnet_ids[1],
    module.network.private_subnet_ids[2],
    module.network.private_subnet_ids[3],
  ]
  node_instance_type = "t3.medium"
  node_min_size      = 1
  node_max_size      = 2
  node_desired_size  = 1
  loki_url           = "http://${aws_eip.monitoring.public_ip}:3100"
}

# ── Monitoring EC2 ────────────────────────────────────────────────────────────
# Prometheus + Grafana + Loki run on a dedicated t3.small EC2 instance rather
# than inside EKS. This frees ~600 MB RAM on the single t3.medium node and
# prevents kube-prometheus-stack from timing out during helm install.

resource "aws_eip" "monitoring" {
  domain = "vpc"
  tags   = { Name = "bookstore-monitoring-eip" }
}

module "monitoring_ec2" {
  source = "./modules/monitoring-ec2"

  vpc_id                    = module.network.vpc_id
  vpc_cidr                  = local.vpc_cidr
  public_subnet_id          = module.network.public_subnet_ids[0]
  eip_allocation_id         = aws_eip.monitoring.id
  cluster_name              = module.eks.cluster_name
  region                    = var.aws_region
  eks_node_sg_id            = module.eks.cluster_security_group_id
  grafana_admin_secret_arn  = module.eks_addons.grafana_admin_secret_arn
  grafana_admin_secret_name = "/bookstore/grafana-admin"
  admin_cidr_blocks         = var.monitoring_admin_cidr

  depends_on = [module.eks_addons]
}

# ── EKS Add-ons ────────────────────────────────────────────────────────────────

module "eks_addons" {
  source            = "./modules/eks-addons"
  cluster_name      = module.eks.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
  node_role_name    = module.eks.node_role_name

  depends_on = [module.eks]
}
