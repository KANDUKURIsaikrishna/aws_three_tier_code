# ── Networking ─────────────────────────────────────────────────────────────────

module "network" {
  source          = "./modules/network"
  vpc_cidr        = local.vpc_cidr
  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets
}

# ── Security Groups ────────────────────────────────────────────────────────────

module "security_groups" {
  source               = "./modules/security"
  vpc_id               = module.network.vpc_id
  prefix               = "bookstore"
  eks_node_cidr_blocks = local.eks_node_subnet_cidrs
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
  # Empty unless explicitly opted in -- var.secondary_region alone used to be
  # enough to silently create a live cross-region secret replica on every
  # apply, DR intent or not. See OBS-049.
  secondary_region = var.enable_dr_replication ? var.secondary_region : ""
}

# ── Per-service DB credentials ─────────────────────────────────────────────────
# Own schema + own DB user inside the existing RDS instance, per service. Full
# per-service RDS isolation is explicitly deferred (see design spec
# Non-goals) — this is schema-level isolation, the cheap intermediate step.
# One for_each block instead of 4 near-identical copies (previously ~110
# lines, one per service, differing only in secret name/DB username/DB name).

locals {
  db_service_credentials = {
    catalog      = { db_name = "catalog_db", db_username = "catalog_user" }
    user         = { db_name = "user_db", db_username = "user_service_user" }
    order        = { db_name = "order_db", db_username = "order_service_user" }
    notification = { db_name = "notification_db", db_username = "notification_service_user" }
  }
}

resource "random_password" "db_credentials" {
  for_each         = local.db_service_credentials
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}?"
}

resource "aws_secretsmanager_secret" "db_credentials" {
  for_each                = local.db_service_credentials
  name                    = "/bookstore/${each.key}-db-credentials"
  recovery_window_in_days = 0 # 0 = force delete on destroy, matches modules/rds pattern
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  for_each  = local.db_service_credentials
  secret_id = aws_secretsmanager_secret.db_credentials[each.key].id
  secret_string = jsonencode({
    DB_USERNAME = each.value.db_username
    DB_PASSWORD = random_password.db_credentials[each.key].result
    DB_HOST     = module.rds.rds_endpoint
    DB_NAME     = each.value.db_name
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

# ── Route 53 ──────────────────────────────────────────────────────────────────
# Private zone for in-cluster RDS DNS + public zone with active-passive failover.

module "route53" {
  source       = "./modules/route53"
  vpc_id       = module.network.vpc_id
  rds_endpoint = module.rds.rds_endpoint
  domain       = var.domain
  # local.primary_alb_dns (argocd.tf) auto-discovers the ALB's hostname
  # within this same apply, falling back to var.primary_alb_dns only
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
  # Empty unless explicitly opted in -- see the matching comment on
  # module.rds's secondary_region above. OBS-029's "6 orphaned ECR repos in
  # us-west-2 post-destroy" mystery was this: every apply silently created
  # them regardless of DR intent.
  secondary_region = var.enable_dr_replication ? var.secondary_region : ""
  extra_repos      = ["catalog-service", "user-service", "order-service", "notification-service", "api-gateway"]
}

# ── EKS ────────────────────────────────────────────────────────────────────────

module "eks" {
  source          = "./modules/eks"
  cluster_name    = "bookstore-eks"
  cluster_version = "1.31"
  prefix          = "bookstore"
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
  region             = var.aws_region

  # Whoever runs `terraform apply` always gets cluster-admin, regardless of who
  # originally created the cluster — see TF-013 in docs/phase-2-troubleshooting.md.
  admin_principal_arns = concat(
    [data.aws_caller_identity.current.arn],
    var.extra_admin_principal_arns
  )
}

# ── Alert email (SES SMTP for Alertmanager) ────────────────────────────────────
# SES account starts in sandbox mode: both sender and recipient must be
# verified addresses. aws_sesv2_email_identity below triggers AWS's
# verification email automatically on create -- click the link it sends to
# var.alert_email before alerts will actually deliver (SES silently bounces
# to unverified recipients otherwise). SMTP AUTH needs a *derived* SMTP
# password, not the raw IAM secret access key -- AWS's own documented
# conversion algorithm (HMAC-SHA256 chain, keyed with a fixed placeholder
# date "11111111" since IAM keys don't expire the way SigV4 requests do) is
# reproduced in the null_resource below. No Terraform-native HMAC function
# exists for this, so it shells out to python3 (already present on any dev
# machine that can run this repo's other scripts) and writes the result
# straight to Secrets Manager -- the derived password itself never touches
# Terraform state.

resource "aws_sesv2_email_identity" "alerts" {
  email_identity = var.alert_email
}

resource "aws_iam_user" "ses_smtp" {
  name = "bookstore-ses-smtp"
}

resource "aws_iam_user_policy" "ses_smtp_send" {
  name = "ses-send"
  user = aws_iam_user.ses_smtp.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "ses:SendRawEmail"
      # Scoped to the one identity this project ever sends from/verifies —
      # SES supports resource-level ARNs for this action, no reason to grant
      # send-as-anyone-verified-in-this-account.
      Resource = aws_sesv2_email_identity.alerts.arn
    }]
  })
}

resource "aws_iam_access_key" "ses_smtp" {
  user = aws_iam_user.ses_smtp.name
}

resource "aws_secretsmanager_secret" "alertmanager_smtp" {
  name                    = "/bookstore/alertmanager-smtp"
  recovery_window_in_days = 0
}

# No aws_secretsmanager_secret_version here on purpose -- the SMTP password
# can only be computed after the access key exists, and that computation
# happens in the null_resource below, not in an HCL expression.
resource "null_resource" "ses_smtp_password" {
  triggers = {
    access_key_id = aws_iam_access_key.ses_smtp.id
  }

  provisioner "local-exec" {
    environment = {
      SECRET_KEY = aws_iam_access_key.ses_smtp.secret
      ACCESS_KEY = aws_iam_access_key.ses_smtp.id
      REGION     = var.aws_region
      SECRET_ID  = aws_secretsmanager_secret.alertmanager_smtp.id
      FROM_EMAIL = var.alert_email
      TO_EMAIL   = var.alert_email
    }
    command = <<-EOT
      python3 <<'PYEOF'
import hmac, hashlib, base64, json, os, subprocess

def sign(key, msg):
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()

def derive_smtp_password(secret_key, region):
    date = "11111111"
    k = sign(("AWS4" + secret_key).encode("utf-8"), date)
    k = sign(k, region)
    k = sign(k, "ses")
    k = sign(k, "aws4_request")
    k = sign(k, "SendRawEmail")
    return base64.b64encode(bytes([0x04]) + k).decode("utf-8")

region = os.environ["REGION"]
secret = {
    "SMTP_HOST": f"email-smtp.{region}.amazonaws.com",
    "SMTP_PORT": "587",
    "SMTP_USERNAME": os.environ["ACCESS_KEY"],
    "SMTP_PASSWORD": derive_smtp_password(os.environ["SECRET_KEY"], region),
    "SMTP_FROM": os.environ["FROM_EMAIL"],
    "SMTP_TO": os.environ["TO_EMAIL"],
}
subprocess.run(
    ["aws", "secretsmanager", "put-secret-value",
     "--secret-id", os.environ["SECRET_ID"],
     "--region", region,
     "--secret-string", json.dumps(secret)],
    check=True,
)
PYEOF
    EOT
  }

  depends_on = [aws_secretsmanager_secret.alertmanager_smtp]
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
  eks_cluster_sg_id         = module.eks.cluster_security_group_id
  eks_api_server            = module.eks.cluster_endpoint
  grafana_admin_secret_arn  = module.eks_addons.grafana_admin_secret_arn
  grafana_admin_secret_name = "/bookstore/grafana-admin"
  admin_cidr_blocks         = var.monitoring_admin_cidr

  monitoring_basic_auth_secret_arn  = module.eks_addons.monitoring_basic_auth_secret_arn
  monitoring_basic_auth_secret_name = "/bookstore/monitoring-basic-auth"

  alertmanager_smtp_secret_arn  = aws_secretsmanager_secret.alertmanager_smtp.arn
  alertmanager_smtp_secret_name = aws_secretsmanager_secret.alertmanager_smtp.name

  # No blanket depends_on module.eks_addons here on purpose. This module only
  # needs module.eks (cluster_name, eks_cluster_sg_id) and the grafana secret's
  # ARN — the latter is already an implicit dependency via the reference above,
  # and that secret (random_password + aws_secretsmanager_secret) is one of the
  # fastest resources in eks_addons, not gated on any of its slow Helm installs
  # (external-secrets/aws-load-balancer-controller/argocd/argo-rollouts, up to
  # 900s timeout each). A module-level depends_on would force this EC2 to wait
  # for ALL of those regardless, which it doesn't actually need.
  #
  # null_resource.ses_smtp_password IS an explicit depends_on -- the ARN
  # reference above only orders against the empty secret shell
  # (aws_secretsmanager_secret), not the local-exec that actually populates
  # it, so without this the instance could boot and fetch the secret before
  # the SMTP password has been written.
  depends_on = [null_resource.ses_smtp_password]
}

# ── EKS Add-ons ────────────────────────────────────────────────────────────────

module "eks_addons" {
  source            = "./modules/eks-addons"
  cluster_name      = module.eks.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  aws_region        = var.aws_region
  node_role_name    = module.eks.node_role_name

  # module.network explicitly, not just module.eks: nothing in eks_addons
  # references the NAT gateway's ID directly (EKS/node group reference
  # subnet IDs, not the NAT resource itself), so module.eks alone doesn't
  # force NAT to outlive this module's destroy. null_resource.delete_ingress_objects
  # (aws-load-balancer-controller.tf) and the AWS Load Balancer Controller pod
  # it triggers both need real internet egress via NAT to reach the EC2/ELBv2
  # APIs and actually tear down the ALB -- lost that once NAT gateway was
  # destroyed concurrently in a real `terraform destroy`, leaving the
  # controller retrying into a dead network forever (i/o timeout on every
  # AWS API call) while the ALB sat orphaned, blocking subnet/IGW/ACM
  # cleanup behind it. See TROUBLESHOOTING.md for the full incident.
  depends_on = [module.eks, module.network]
}
