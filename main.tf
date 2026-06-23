terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
  }

  # ── Remote State ────────────────────────────────────────────────────────
  # Run scripts/bootstrap-tf-state.sh ONCE to create the S3 bucket and
  # DynamoDB lock table. After substituting values below, run:
  # terraform init -migrate-state
  #
  backend "s3" {
    bucket         = ""
    key            = "prod/terraform.tfstate"
    region         = "us-west-1"
    dynamodb_table = ""
    encrypt        = true
  }
}

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

# ── Input Variables ────────────────────────────────────────────────────────

variable "aws_region" {
  type    = string
  default = "us-west-1"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "domain" {
  type        = string
  description = "Primary domain for ACM cert and Route 53 (e.g. example.com)"
  default     = "your-domain.com"
}

variable "github_repo" {
  type        = string
  description = "GitHub repo that assumes the OIDC CI role, in owner/name format"
  default     = "YOUR_GITHUB_USERNAME/aws_three_tier_code"
}

# ── Networking ─────────────────────────────────────────────────────────────

module "network" {
  source   = "./modules/network"
  vpc_cidr = "170.20.0.0/16"

  public_subnets = [
    { cidr = "170.20.1.0/24", az = "us-west-1a" },
    { cidr = "170.20.2.0/24", az = "us-west-1c" }
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

output "vpc_id" {
  value = module.network.vpc_id
}

# ── Security Groups ────────────────────────────────────────────────────────

module "security_groups" {
  source = "./modules/security"
  vpc_id = module.network.vpc_id
  prefix = "bookstore"
}

# ── ACM Certificate ────────────────────────────────────────────────────────

module "acm" {
  source      = "./modules/acm"
  domain_name = var.domain
  san_names   = ["*.${var.domain}"]
}

# ── RDS ────────────────────────────────────────────────────────────────────

module "rds" {
  source               = "./modules/rds"
  db_identifier        = "bookstore-db"
  db_engine            = "mysql"
  db_engine_version    = "8.0"
  db_instance_class    = "db.t3.micro"
  db_allocated_storage = 25
  db_name              = "test"
  db_username          = "admin"
  db_security_group_id = module.security_groups.rds_sg_id
  db_subnet_ids        = [
    module.network.private_subnet_ids[4],
    module.network.private_subnet_ids[5],
  ]
  multi_az                = true
  backup_retention_period = 7
  deletion_protection     = false
}

output "rds_endpoint" {
  value = module.rds.rds_endpoint
}

output "rds_secret_arn" {
  value     = module.rds.master_user_secret_arn
  sensitive = true
}

# ── Route 53 (private zone for RDS; public DNS managed by ExternalDNS) ────

module "route53" {
  source       = "./modules/route53"
  vpc_id       = module.network.vpc_id
  rds_endpoint = module.rds.rds_endpoint
}

# ── ECR ────────────────────────────────────────────────────────────────────

module "ecr" {
  source                = "./modules/ecr"
  prefix                = "bookstore"
  image_retention_count = 10
}

output "frontend_repo_url" { value = module.ecr.frontend_repo_url }
output "backend_repo_url"  { value = module.ecr.backend_repo_url }

# ── EKS ────────────────────────────────────────────────────────────────────

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

output "eks_cluster_name"      { value = module.eks.cluster_name }
output "eks_cluster_endpoint"  { value = module.eks.cluster_endpoint }
output "eks_oidc_provider_arn" { value = module.eks.oidc_provider_arn }

# ── Helm provider (auth via aws eks get-token — no static kubeconfig) ─────────

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

# ── EKS add-ons (cert-manager, ESO, ingress-nginx, ArgoCD, EBS CSI) ───────────

module "eks_addons" {
  source = "./modules/eks-addons"

  cluster_name      = module.eks.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
  aws_region        = var.aws_region
  node_role_name    = module.eks.node_role_name

  depends_on = [module.eks]
}

# ── GitHub Actions OIDC Role ───────────────────────────────────────────────
# Lets GitHub Actions assume an AWS role via OIDC — no static AWS keys.
# Prerequisites (one-time, outside Terraform):
#   aws iam create-open-id-connect-provider \
#     --url https://token.actions.githubusercontent.com \
#     --client-id-list sts.amazonaws.com \
#     --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1

data "aws_caller_identity" "current" {}

resource "aws_iam_role" "github_oidc" {
  name = "bookstore-github-oidc-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = {
        Federated = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"
      }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:*"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_oidc_ecr" {
  name = "ecr-push"
  role = aws_iam_role.github_oidc.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
        ]
        Resource = "arn:aws:ecr:us-west-1:${data.aws_caller_identity.current.account_id}:repository/bookstore-*"
      },
    ]
  })
}

output "github_oidc_role_arn" { value = aws_iam_role.github_oidc.arn }
