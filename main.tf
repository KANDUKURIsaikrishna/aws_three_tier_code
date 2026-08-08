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
  deletion_protection     = false # flipped off for today's destroy — AWS refuses DeleteDBInstance while true
  skip_final_snapshot     = true  # avoids a lingering snapshot + naming collision on next apply
  secondary_region        = var.secondary_region
}

# ── Catalog Service — DB credentials ──────────────────────────────────────────
# Own schema + own DB user inside the existing RDS instance. Full per-service
# RDS isolation is explicitly deferred (see design spec Non-goals) — this is
# schema-level isolation, the cheap intermediate step.

resource "random_password" "catalog_db_password" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}?"
}

resource "aws_secretsmanager_secret" "catalog_db_credentials" {
  name                    = "/bookstore/catalog-db-credentials"
  recovery_window_in_days = 0 # 0 = force delete on destroy, matches modules/rds pattern
}

resource "aws_secretsmanager_secret_version" "catalog_db_credentials" {
  secret_id = aws_secretsmanager_secret.catalog_db_credentials.id
  secret_string = jsonencode({
    DB_USERNAME = "catalog_user"
    DB_PASSWORD = random_password.catalog_db_password.result
    DB_HOST     = module.rds.rds_endpoint
    DB_NAME     = "catalog_db"
  })
}

# ── User Service — DB credentials ─────────────────────────────────────────────

resource "random_password" "user_db_password" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}?"
}

resource "aws_secretsmanager_secret" "user_db_credentials" {
  name                    = "/bookstore/user-db-credentials"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "user_db_credentials" {
  secret_id = aws_secretsmanager_secret.user_db_credentials.id
  secret_string = jsonencode({
    DB_USERNAME = "user_service_user"
    DB_PASSWORD = random_password.user_db_password.result
    DB_HOST     = module.rds.rds_endpoint
    DB_NAME     = "user_db"
  })
}

# ── Shared JWT signing secret ──────────────────────────────────────────────────
# user-service issues tokens; api-gateway and order-service (built in later
# plans) each add their own ExternalSecret reading this same entry to verify
# them. HS256 (symmetric) — one shared secret, not a keypair.

resource "random_password" "jwt_secret" {
  length  = 64
  special = false # JWT secret goes straight into an env var; avoid shell-metacharacter escaping issues
}

resource "aws_secretsmanager_secret" "jwt_secret" {
  name                    = "/bookstore/jwt-secret"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "jwt_secret" {
  secret_id = aws_secretsmanager_secret.jwt_secret.id
  secret_string = jsonencode({
    JWT_SECRET = random_password.jwt_secret.result
  })
}

# ── Order Service — DB credentials ────────────────────────────────────────────

resource "random_password" "order_db_password" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}?"
}

resource "aws_secretsmanager_secret" "order_db_credentials" {
  name                    = "/bookstore/order-db-credentials"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "order_db_credentials" {
  secret_id = aws_secretsmanager_secret.order_db_credentials.id
  secret_string = jsonencode({
    DB_USERNAME = "order_service_user"
    DB_PASSWORD = random_password.order_db_password.result
    DB_HOST     = module.rds.rds_endpoint
    DB_NAME     = "order_db"
  })
}

# ── Notification Service — DB credentials ─────────────────────────────────────

resource "random_password" "notification_db_password" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}?"
}

resource "aws_secretsmanager_secret" "notification_db_credentials" {
  name                    = "/bookstore/notification-db-credentials"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "notification_db_credentials" {
  secret_id = aws_secretsmanager_secret.notification_db_credentials.id
  secret_string = jsonencode({
    DB_USERNAME = "notification_service_user"
    DB_PASSWORD = random_password.notification_db_password.result
    DB_HOST     = module.rds.rds_endpoint
    DB_NAME     = "notification_db"
  })
}

# ── Route 53 ──────────────────────────────────────────────────────────────────
# Private zone for in-cluster RDS DNS + public zone with active-passive failover.

module "route53" {
  source       = "./modules/route53"
  vpc_id       = module.network.vpc_id
  rds_endpoint = module.rds.rds_endpoint
  domain       = var.domain
  # local.primary_alb_dns (argocd.tf) auto-discovers the ingress-nginx NLB
  # hostname within this same apply, falling back to var.primary_alb_dns only
  # if that's explicitly set — no more manual second-apply for this value.
  primary_alb_dns   = local.primary_alb_dns
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
  extra_repos           = ["catalog-service", "user-service", "order-service", "notification-service", "api-gateway"]
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
  node_instance_type = "t3.medium"
  node_min_size      = 1
  node_max_size      = 3
  node_desired_size  = 3 # t3.medium caps at 17 pods (ENI IP limit); 2 nodes (34 slots) filled up once all 5 microservices + api-gateway (2 replicas) joined the monolith — see TF-014, OBS-030
  loki_url           = "http://${aws_eip.monitoring.public_ip}:3100"

  # Whoever runs `terraform apply` always gets cluster-admin, regardless of who
  # originally created the cluster — see TF-013 in docs/phase-2-troubleshooting.md.
  admin_principal_arns = concat(
    [data.aws_caller_identity.current.arn],
    var.extra_admin_principal_arns
  )
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

  # No blanket depends_on module.eks_addons here on purpose. This module only
  # needs module.eks (cluster_name, eks_node_sg_id) and the grafana secret's
  # ARN — the latter is already an implicit dependency via the reference above,
  # and that secret (random_password + aws_secretsmanager_secret) is one of the
  # fastest resources in eks_addons, not gated on any of its slow Helm installs
  # (cert-manager/external-secrets/ingress-nginx/argocd/argo-rollouts, up to
  # 900s timeout each). A module-level depends_on would force this EC2 to wait
  # for ALL of those regardless, which it doesn't actually need.
}

# ── EKS Add-ons ────────────────────────────────────────────────────────────────

module "eks_addons" {
  source            = "./modules/eks-addons"
  cluster_name      = module.eks.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  aws_region        = var.aws_region
  node_role_name    = module.eks.node_role_name

  depends_on = [module.eks]
}
