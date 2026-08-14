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
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
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
  #
  # workspace_key_prefix makes state workspace-aware: the "default" workspace
  # (what a plain `terraform apply` uses if you never run `terraform
  # workspace`) still resolves to exactly `key` below, so this is a no-op for
  # today's single-environment usage. Running `terraform workspace new
  # staging` gets its own isolated state at
  # `environments/staging/terraform.tfstate` automatically, no key changes
  # needed by hand. See docs/TERRAFORM.md#environments for the full workflow
  # and its current limits -- state isolation is real, resource *naming*
  # isolation (e.g. two workspaces both trying to create an EKS cluster named
  # "bookstore-eks" in the same account) is not solved by this alone.
  backend "s3" {
    bucket               = ""
    key                  = "terraform.tfstate"
    workspace_key_prefix = "environments"
    region               = "us-west-1"
    dynamodb_table       = ""
    encrypt              = true
  }
}
