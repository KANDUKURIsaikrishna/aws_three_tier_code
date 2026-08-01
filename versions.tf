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
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    kubectl = {
      # gavinbunney/kubectl, not hashicorp — deliberately, for applying the
      # existing ArgoCD Application/ApplicationSet YAML as-is. Its
      # kubectl_manifest resource defers schema validation to apply time,
      # unlike hashicorp/kubernetes's kubernetes_manifest, which needs the
      # CRD to already exist at plan time — a real problem here since the
      # Application/ApplicationSet CRDs are installed by the argocd Helm
      # release in the SAME apply, not before it.
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }

  # Run scripts/bootstrap-tf-state.sh once to create the S3 bucket and
  # DynamoDB table. Fill in the values below, then: terraform init -migrate-state
  backend "s3" {
    bucket         = ""
    key            = "prod/terraform.tfstate"
    region         = "us-west-1"
    dynamodb_table = ""
    encrypt        = true
  }
}
