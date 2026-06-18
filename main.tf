terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
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
  domain_name = "b17facebook.xyz"
  san_names   = ["*.b17facebook.xyz"]
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

  node_instance_type = "t3.medium"
  node_min_size      = 1
  node_max_size      = 4
  node_desired_size  = 2
}

output "eks_cluster_name"      { value = module.eks.cluster_name }
output "eks_cluster_endpoint"  { value = module.eks.cluster_endpoint }
output "eks_oidc_provider_arn" { value = module.eks.oidc_provider_arn }
