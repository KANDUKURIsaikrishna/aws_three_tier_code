terraform {
  # >= 1.10.0 for native S3 state locking (use_lockfile) -- no DynamoDB table needed.
  required_version = ">= 1.10.0"

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

  # Run scripts/init-backend.sh once to create the S3 bucket. Fill in the
  # values below, then: terraform init -migrate-state
  #
  # use_lockfile enables S3's native state locking (conditional writes --
  # no DynamoDB table required). Requires Terraform >= 1.10.0. Replaces the
  # old S3+DynamoDB pattern: one less resource to provision, pay for, and
  # orphan on teardown.
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
    bucket         = "bookstore-terraform-state-905221885307"
    key                  = "terraform.tfstate"
    workspace_key_prefix = "environments"
    region               = "us-west-1"
    use_lockfile         = true
    encrypt              = true
  }
}
