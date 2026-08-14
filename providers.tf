provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "bookstore"
      Environment = var.environment
      ManagedBy   = "terraform"
      CostCenter  = var.cost_center
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
      CostCenter  = var.cost_center
    }
  }
}

# CloudFront ACM certs must be in us-east-1 — AWS hard requirement, regardless of secondary DR region.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project     = "bookstore"
      Environment = var.environment
      ManagedBy   = "terraform"
      CostCenter  = var.cost_center
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

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
  }
}

provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)
  load_config_file       = false
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
  }
}
