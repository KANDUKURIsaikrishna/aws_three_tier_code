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
