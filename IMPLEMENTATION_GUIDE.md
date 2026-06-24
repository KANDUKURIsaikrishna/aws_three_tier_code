# Bookstore — Complete Implementation Guide

This guide walks you through standing up the entire Bookstore application from zero: a three-tier architecture on AWS with Terraform-managed infrastructure, containerised workloads on EKS, GitOps delivery via ArgoCD, and a DevSecOps CI/CD pipeline on GitHub Actions.

Follow every part in order on a first deployment. After initial setup, only Parts 7–9 are repeated for each new release.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites](#2-prerequisites)
3. [Part 0 — One-time Configuration](#part-0--one-time-configuration)
4. [Part 1 — AWS Account Setup](#part-1--aws-account-setup)
5. [Part 2 — Bootstrap Terraform Remote State](#part-2--bootstrap-terraform-remote-state)
6. [Part 3 — Provision Infrastructure with Terraform](#part-3--provision-infrastructure-with-terraform)
7. [Part 4 — Bootstrap the EKS Cluster](#part-4--bootstrap-the-eks-cluster)
8. [Part 5 — Configure Secret Management](#part-5--configure-secret-management)
9. [Part 6 — GitHub Repository Setup](#part-6--github-repository-setup)
10. [Part 7 — Apply Configuration and First Deploy](#part-7--apply-configuration-and-first-deploy)
11. [Part 8 — First Deployment](#part-8--first-deployment)
12. [Part 9 — DNS and TLS Configuration](#part-9--dns-and-tls-configuration)
13. [Part 10 — Verify the Application](#part-10--verify-the-application)
14. [Part 11 — Local Development Setup](#part-11--local-development-setup)
15. [Troubleshooting](#troubleshooting)

---

## 1. Architecture Overview

### 1.1 Full System Diagram

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           AWS — us-west-1                                        │
│                                                                                 │
│   ┌─────────────────────────────────────────────────────────────────────────┐   │
│   │  VPC  170.20.0.0/16                                                     │   │
│   │                                                                         │   │
│   │  ┌──────────────────────────────────────────────────────────────────┐   │   │
│   │  │  Public Subnets                                                  │   │   │
│   │  │                                                                  │   │   │
│   │  │   us-west-1a (170.20.1.0/24)    us-west-1c (170.20.2.0/24)      │   │   │
│   │  │   ┌──────────────────────┐      ┌──────────────────────┐        │   │   │
│   │  │   │  Internet Gateway    │      │   NAT Gateway         │        │   │   │
│   │  │   │  Nginx Ingress NLB   │      │   (outbound traffic)  │        │   │   │
│   │  │   └──────────────────────┘      └──────────────────────┘        │   │   │
│   │  └──────────────────────────────────────────────────────────────────┘   │   │
│   │                        │                        │                        │   │
│   │                        ▼ HTTPS                  │ NAT                    │   │
│   │  ┌──────────────────────────────────────────────────────────────────┐   │   │
│   │  │  Private Subnets — App Tier (EKS)                                │   │   │
│   │  │                                                                  │   │   │
│   │  │   us-west-1a (170.20.3.0/24)    us-west-1c (170.20.4.0/24)      │   │   │
│   │  │   ┌──────────────────────────────────────────────────────────┐   │   │   │
│   │  │   │  EKS Managed Node Group  (t3.medium × 1–2 nodes)         │   │   │   │
│   │  │   │                                                          │   │   │   │
│   │  │   │  bookstore namespace                                     │   │   │   │
│   │  │   │  ┌────────────────┐  ┌─────────────────┐                │   │   │   │
│   │  │   │  │ Frontend Pods  │  │  Backend Pods    │                │   │   │   │
│   │  │   │  │ React / Nginx  │  │  Node.js/Express │                │   │   │   │
│   │  │   │  │ replicas: 1    │  │  Argo Rollout    │                │   │   │   │
│   │  │   │  └────────────────┘  └─────────────────┘                │   │   │   │
│   │  │   │         ▲                    │                           │   │   │   │
│   │  │   │  Nginx Ingress          MySQL StatefulSet                │   │   │   │
│   │  │   │  (ingress-nginx ns)     (dev / local only)              │   │   │   │
│   │  │   │                              │ in prod → RDS             │   │   │   │
│   │  │   └──────────────────────────────────────────────────────────┘   │   │   │
│   │  │                                  │                                │   │   │
│   │  │   monitoring namespace           │                                │   │   │
│   │  │   Prometheus + Grafana           │                                │   │   │
│   │  └──────────────────────────────────────────────────────────────────┘   │   │
│   │                                                                         │   │
│   │  ┌──────────────────────────────────────────────────────────────────┐   │   │
│   │  │  Private Subnets — Data Tier                                     │   │   │
│   │  │                                                                  │   │   │
│   │  │   us-west-1a (170.20.7.0/24)    us-west-1c (170.20.8.0/24)      │   │   │
│   │  │   ┌──────────────────────────────────────────────────────────┐   │   │   │
│   │  │   │  RDS MySQL 8.0  (db.t3.micro, Multi-AZ, deletion-protect)│   │   │   │
│   │  │   └──────────────────────────────────────────────────────────┘   │   │   │
│   │  └──────────────────────────────────────────────────────────────────┘   │   │
│   └─────────────────────────────────────────────────────────────────────────┘   │
│                                                                                 │
│   ┌──────────────────────────────┐   ┌────────────────────────────────────┐    │
│   │  Amazon ECR                  │   │  AWS Secrets Manager               │    │
│   │  bookstore-frontend (repo)   │   │  /bookstore/db-credentials         │    │
│   │  bookstore-backend  (repo)   │   │  (username + password)             │    │
│   └──────────────────────────────┘   └────────────────────────────────────┘    │
│                                                                                 │
│   ┌──────────────────────────────┐   ┌────────────────────────────────────┐    │
│   │  S3 Bucket (Terraform state) │   │  DynamoDB (state lock)             │    │
│   │  bookstore-terraform-state-* │   │  terraform-state-lock              │    │
│   └──────────────────────────────┘   └────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### 1.2 CI/CD and GitOps Flow

```
Developer pushes code
         │
         ▼
┌────────────────────────────────────────────────────────────────────────┐
│  GitHub Actions — DevSecOps Pipeline                                   │
│  Triggers on push/PR to main OR improvements branches                  │
│                                                                        │
│  Stage 0: Secret Scan      Stage 1: SAST              Stage 2: Lint   │
│  ┌─────────────────────┐   ┌──────────────────────┐   ┌────────────┐  │
│  │  Gitleaks           │   │  npm test (vitest)   │   │  ESLint    │  │
│  │  Full git history   │ → │  npm audit --omit=dev│   │  kubeval   │  │
│  └─────────────────────┘   │  Semgrep (OWASP)     │   └────────────┘  │
│                            └──────────────────────┘         │         │
│                                    │                         │         │
│                                    └──────────┬──────────────┘         │
│                                               ▼                        │
│                              Stage 3: Build → Scan → Push              │
│                              (runs on main OR improvements branches)   │
│                              ┌──────────────────────────────────────┐  │
│                              │  docker build backend                │  │
│                              │  Trivy scan → SARIF → GitHub Security│  │
│                              │  docker push → ECR                   │  │
│                              │  (same for frontend)                 │  │
│                              └──────────────────────────────────────┘  │
│                                               │                        │
│                                    Manual approval gate                │
│                                    (GitHub Environment: production)    │
│                                               │                        │
│                              Stage 4: Update image tags (GitOps)      │
│                              ┌──────────────────────────────────────┐  │
│                              │  cd k8s/overlays/prod                │  │
│                              │  kustomize edit set image            │  │
│                              │  git commit k8s/overlays/prod/       │  │
│                              │    kustomization.yaml                │  │
│                              │  git push (GITHUB_TOKEN)             │  │
│                              └──────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────────┘
                                               │
                                               ▼ (commit detected, ~3 min)
┌────────────────────────────────────────────────────────────────────────┐
│  ArgoCD (running in EKS, argocd namespace)                             │
│                                                                        │
│  Polls GitHub repo → detects new commit in                            │
│    k8s/overlays/prod/kustomization.yaml                               │
│  Runs: kustomize build k8s/overlays/prod/                             │
│  Applies diff to bookstore namespace                                   │
│  Backend: Argo Rollout canary (10% → 50% → 100%)                     │
│  selfHeal: true → reverts any manual kubectl changes                  │
└────────────────────────────────────────────────────────────────────────┘
```

### 1.3 Secret Management Chain

```
AWS Secrets Manager
  /bookstore/db-credentials
  {"DB_USERNAME":"admin","DB_PASSWORD":"..."}
          │
          │  IRSA (IAM Role for Service Account)
          │  No credentials leave AWS
          ▼
External Secrets Operator (external-secrets namespace)
  ClusterSecretStore → reads from Secrets Manager
  ExternalSecret      → creates k8s Secret "db-secret"
          │
          ▼
k8s Secret "db-secret" in bookstore namespace
  (in-cluster only, never in git or pipeline)
          │
          ▼
Backend pods mount DB_USERNAME and DB_PASSWORD as env vars
```

---

## 2. Prerequisites

Install these tools before starting. Minimum versions are required.

| Tool | Min Version | Install |
|---|---|---|
| AWS CLI | 2.x | https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html |
| Terraform | 1.7 | https://developer.hashicorp.com/terraform/install |
| kubectl | 1.31 | https://kubernetes.io/docs/tasks/tools/ |
| helm | 3.x | https://helm.sh/docs/intro/install/ |
| Docker | 24 | https://docs.docker.com/get-docker/ |
| git | 2.x | https://git-scm.com/downloads |
| Node.js | 18 | https://nodejs.org (for local dev only) |
| kustomize | 5.x | https://kubectl.docs.kubernetes.io/installation/kustomize/ |

Verify each tool is on your PATH:

```bash
aws --version
terraform --version
kubectl version --client
helm version
docker --version
git --version
kustomize version
```

You also need:
- An **AWS account** with administrator access (or a scoped IAM user — see Part 1)
- A **GitHub account** with a repository for this project
- A **registered domain name** with Route 53 as the DNS provider, or the ability to add DNS records wherever your domain is hosted

---

## Part 0 — One-time Configuration

All environment-specific values (account ID, domain, GitHub repo) live in a single gitignored file. Fill it in once; every script and manifest picks up the values automatically.

### Step 0.1 — Create config.env

```bash
# From the repo root
cp config.env.example config.env
```

Open `config.env` and fill in your real values:

```bash
AWS_ACCOUNT_ID=123456789012        # 12-digit account ID (aws sts get-caller-identity)
AWS_REGION=us-west-1
DOMAIN=your-domain.com             # e.g. example.com  — app lives at bookstore.<DOMAIN>
GITHUB_REPO=YOUR_GITHUB_USERNAME/aws_three_tier_code
```

### Step 0.2 — Run the configure script

```bash
python scripts/configure.py
```

What it does:

| Target | What gets written |
|---|---|
| `terraform.tfvars` | `aws_region`, `domain`, `github_repo` variables (gitignored) |
| `k8s/base/ingress/ingress.yaml` | host rules with your real domain |
| `k8s/argocd/application.yaml` | `repoURL` with your real GitHub repo |
| `k8s/overlays/prod/kustomization.yaml` | ECR registry with your real account ID |

> **Re-run this script** any time you change `config.env` (e.g. domain change, new account). It is idempotent.

> `config.env` and `terraform.tfvars` are in `.gitignore` — never commit them.

---

## Part 1 — AWS Account Setup

### Step 1.1 — Configure the AWS CLI

```bash
aws configure
# AWS Access Key ID:     <your-access-key>
# AWS Secret Access Key: <your-secret-key>
# Default region name:   us-west-1
# Default output format: json
```

Verify it works:

```bash
aws sts get-caller-identity
# Expected output:
# {
#   "UserId": "AIDA...",
#   "Account": "123456789012",
#   "Arn": "arn:aws:iam::123456789012:user/yourname"
# }
```

Save your account ID — you will need it in several steps:

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export AWS_REGION=us-west-1
echo "Account ID: $ACCOUNT_ID"
```

---

### Step 1.2 — Create the GitHub OIDC IAM Role

The CI/CD pipeline authenticates to AWS using **GitHub OIDC token exchange** — no static access keys are stored anywhere. This role must be created before the pipeline can run.

**1. Register GitHub as an OIDC identity provider in IAM (one-time per account):**

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

If the provider already exists you will get a `EntityAlreadyExists` error — that is fine, continue.

**2. Create the trust policy file:**

> `GITHUB_REPO` and `ACCOUNT_ID` come from `config.env` (set in Part 0). Source it first if you haven't already:
> ```bash
> source config.env
> export ACCOUNT_ID=$AWS_ACCOUNT_ID
> ```

```bash
cat > /tmp/github-oidc-trust.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:${GITHUB_REPO}:*"
        }
      }
    }
  ]
}
EOF
```

**3. Create the IAM role:**

```bash
aws iam create-role \
  --role-name bookstore-github-oidc-role \
  --assume-role-policy-document file:///tmp/github-oidc-trust.json
```

**4. Create the permissions policy:**

```bash
cat > /tmp/github-oidc-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ECRAuth",
      "Effect": "Allow",
      "Action": "ecr:GetAuthorizationToken",
      "Resource": "*"
    },
    {
      "Sid": "ECRPush",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:PutImage",
        "ecr:DescribeImages",
        "ecr:ListImages"
      ],
      "Resource": [
        "arn:aws:ecr:${AWS_REGION}:${ACCOUNT_ID}:repository/bookstore-frontend",
        "arn:aws:ecr:${AWS_REGION}:${ACCOUNT_ID}:repository/bookstore-backend"
      ]
    },
    {
      "Sid": "EKSDescribe",
      "Effect": "Allow",
      "Action": "eks:DescribeCluster",
      "Resource": "arn:aws:eks:${AWS_REGION}:${ACCOUNT_ID}:cluster/bookstore-eks"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name bookstore-github-oidc-role \
  --policy-name bookstore-github-oidc-policy \
  --policy-document file:///tmp/github-oidc-policy.json
```

**5. Note the role ARN for later:**

```bash
aws iam get-role \
  --role-name bookstore-github-oidc-role \
  --query "Role.Arn" --output text
# arn:aws:iam::123456789012:role/bookstore-github-oidc-role
```

---

## Part 2 — Bootstrap Terraform Remote State

Terraform stores its state file in S3 and uses DynamoDB for state locking. These AWS resources must exist before Terraform can use the remote backend. The bootstrap script creates them once and is safe to re-run.

### Step 2.1 — Run the bootstrap script

```bash
chmod +x scripts/bootstrap-tf-state.sh
./scripts/bootstrap-tf-state.sh us-west-1
```

Expected output:

```
Account : 123456789012
Region  : us-west-1
Bucket  : bookstore-terraform-state-123456789012
Table   : terraform-state-lock

[ok] Bucket created and hardened.
[ok] DynamoDB table created.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Bootstrap complete. Replace the ACCOUNT_ID placeholder in main.tf
backend block with the values below, then run: terraform init -migrate-state
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  backend "s3" {
    bucket         = "bookstore-terraform-state-123456789012"
    key            = "prod/terraform.tfstate"
    region         = "us-west-1"
    dynamodb_table = "terraform-state-lock"
    encrypt        = true
  }
```

### Step 2.2 — Fill in the backend block in main.tf

The S3 backend block cannot use Terraform variables (it is parsed before variables are loaded), so you must edit `main.tf` directly — once. Replace the empty `bucket` and `dynamodb_table` strings with the values printed by the bootstrap script:

```hcl
backend "s3" {
  bucket         = "bookstore-terraform-state-123456789012"   # ← printed by bootstrap script
  key            = "prod/terraform.tfstate"
  region         = "us-west-1"
  dynamodb_table = "terraform-state-lock"
  encrypt        = true
}
```

> **All other project-specific values** (`domain`, `github_repo`) are in `terraform.tfvars`, which was generated by `scripts/configure.py` in Part 0. You do not need to edit `main.tf` for those.

> Do this substitution exactly once. Every subsequent `terraform init` and `terraform apply` reuse the same S3 object.

---

## Part 3 — Provision Infrastructure with Terraform

Terraform provisions the entire AWS foundation: VPC, subnets, security groups, ACM certificate, RDS, ECR repositories, EKS cluster, private DNS for RDS, and all cluster add-ons via the `eks-addons` module.

### Step 3.1 — Initialise Terraform

```bash
terraform init
```

Expected output includes:
```
Initializing the backend...
Successfully configured the backend "s3"!
Initializing provider plugins...
- Installing hashicorp/aws v5.x.x
- Installing hashicorp/helm v2.x.x
Terraform has been successfully initialized!
```

### Step 3.2 — Preview the plan

```bash
terraform plan
```

Review the plan output. Terraform will create approximately 50–60 resources. Look for any unexpected `destroy` actions — there should be none on a fresh account.

### Step 3.3 — Apply

```bash
terraform apply
```

Type `yes` when prompted. This takes **20–30 minutes** because:
- EKS control plane provisioning takes 10–12 minutes
- RDS Multi-AZ instance takes 5–8 minutes
- Helm releases (cert-manager, ESO, ingress-nginx, ArgoCD, Prometheus stack, Argo Rollouts) are installed sequentially after the cluster is ready

### Step 3.4 — What the eks-addons module installs

The `modules/eks-addons/` module installs all cluster platform components via Terraform-managed Helm releases. You do not need to install these manually.

| Component | Helm chart | Namespace |
|---|---|---|
| EBS CSI driver | `aws_eks_addon` (not Helm) | `kube-system` |
| cert-manager | `jetstack/cert-manager` v1.14.4 | `cert-manager` |
| External Secrets Operator | `external-secrets/external-secrets` | `external-secrets` |
| Nginx Ingress | `ingress-nginx/ingress-nginx` v4.9.1 | `ingress-nginx` |
| ArgoCD | `argo/argo-cd` | `argocd` |
| Prometheus + Grafana | `prometheus-community/kube-prometheus-stack` | `monitoring` |
| Argo Rollouts | `argo/argo-rollouts` | `argo-rollouts` |

All components are configured at minimal replica count for the tech demo (1 replica each). AlertManager is disabled.

### Step 3.5 — Capture outputs

After apply completes, save the outputs you will need in later steps:

```bash
terraform output eks_cluster_name
# bookstore-eks

terraform output eks_cluster_endpoint
# https://XXXXXXXX.gr7.us-west-1.eks.amazonaws.com

terraform output rds_endpoint
# bookstore-db.xxxxxxxxxxxx.us-west-1.rds.amazonaws.com

terraform output frontend_repo_url
# 123456789012.dkr.ecr.us-west-1.amazonaws.com/bookstore-frontend

terraform output backend_repo_url
# 123456789012.dkr.ecr.us-west-1.amazonaws.com/bookstore-backend

terraform output eks_oidc_provider_arn
# arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-west-1.amazonaws.com/id/XXXX
```

---

## Part 4 — Bootstrap the EKS Cluster

After `terraform apply` the cluster add-ons are already running. `eks_bootstrap.py` handles the remaining steps that Terraform cannot do: applying the Let's Encrypt ClusterIssuer, creating the IRSA role for External Secrets, validating Secrets Manager credentials, and configuring the ArgoCD Application.

### Step 4.1 — Run eks_bootstrap.py

```bash
# Source config.env so DOMAIN is available, then run the bootstrap script
source config.env
DOMAIN=$DOMAIN python eks_bootstrap.py
```

The script runs **8 phases** in order and is safe to re-run (all steps are idempotent):

| Phase | Action |
|---|---|
| 1 | Sync kubeconfig (`aws eks update-kubeconfig`) |
| 2 | Apply ClusterIssuer (cert-manager CRDs already exist from Terraform) |
| 3 | Create IRSA role + annotate `external-secrets-sa` service account |
| 4 | Validate / create AWS Secrets Manager secret (`/bookstore/db-credentials`) |
| 5 | Apply ArgoCD Application manifest + patch ArgoCD secret key |
| 6 | Clear kubectl discovery cache + force ESO resync |
| 7 | Wait for mysql-0, run DB schema init + seed data |
| 8 | Print summary + Route53 NLB hostname reminder |

Expected output ends with:

```
======================================================================
>>> Phase 8: Bootstrap Summary
======================================================================
Bootstrap complete! ArgoCD will sync within 3 minutes.
   Monitor: kubectl get pods -n bookstore -w
```

If a single phase fails, re-run the script — it picks up where it left off. See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for phase-specific errors.

> **Note:** Unlike earlier versions, `eks_bootstrap.py` no longer installs cert-manager, ESO, ingress-nginx, or ArgoCD — Terraform handles all of that. The script only handles what Terraform cannot: OIDC-cluster-specific IRSA bindings, the ClusterIssuer CRD instance, and the ArgoCD Application manifest.

### Step 4.2 — Access the ArgoCD UI (optional)

```bash
# Port-forward to access the UI locally
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Get the initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo

# Open https://localhost:8080 in a browser
# Username: admin
# Password: (from command above)
```

### Step 4.3 — Connect your GitHub repository to ArgoCD

If your repository is **public**, skip this step.

If your repository is **private**:

```bash
# Install the argocd CLI
curl -sSL -o argocd \
  https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x argocd && sudo mv argocd /usr/local/bin/

# Login
argocd login localhost:8080 \
  --username admin \
  --password $(kubectl -n argocd get secret argocd-initial-admin-secret \
               -o jsonpath="{.data.password}" | base64 -d) \
  --insecure

# Add the repo (use a GitHub Personal Access Token with repo scope)
# GITHUB_REPO comes from config.env — source it first: source config.env
argocd repo add https://github.com/$GITHUB_REPO \
  --username $(echo $GITHUB_REPO | cut -d/ -f1) \
  --password YOUR_GITHUB_PAT
```

---

## Part 5 — Configure Secret Management

Database credentials live only in AWS Secrets Manager. ESO reads them and creates an in-cluster Kubernetes Secret. Nothing touches the pipeline or git.

### Step 5.1 — Store DB credentials in Secrets Manager

`eks_bootstrap.py` Phase 4 will prompt you for credentials interactively if the secret does not exist. Alternatively, create it manually before running the script:

```bash
aws secretsmanager create-secret \
  --name /bookstore/db-credentials \
  --region us-west-1 \
  --description "Bookstore application database credentials" \
  --secret-string '{"DB_USERNAME":"admin","DB_PASSWORD":"<strong-password>"}'
```

Verify the secret was created:

```bash
aws secretsmanager describe-secret \
  --secret-id /bookstore/db-credentials \
  --query "Name" --output text
# /bookstore/db-credentials
```

---

## Part 6 — GitHub Repository Setup

### Step 6.1 — Create GitHub Actions secrets

Go to your GitHub repository → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**.

Create each secret:

| Secret name | Value | Description |
|---|---|---|
| `AWS_ACCOUNT_ID` | `123456789012` | Your 12-digit AWS account ID |
| `AWS_ROLE_ARN` | `arn:aws:iam::123456789012:role/bookstore-github-oidc-role` | OIDC role ARN from Step 1.2 |
| `API_URL` | `https://api.bookstore.<YOUR_DOMAIN>` | Backend API URL injected into the React build (use your domain from config.env) |
| `SEMGREP_APP_TOKEN` | *(optional)* | Semgrep Cloud token. If you don't have one, remove the `SEMGREP_APP_TOKEN` env line from `.github/workflows/ci-cd.yml` |

### Step 6.2 — Create the production GitHub Environment

The pipeline requires a manual approval gate before deploying. This is enforced through a GitHub Environment.

1. Go to your repository → **Settings** → **Environments** → **New environment**
2. Name it exactly: `production`
3. Under **Deployment protection rules**, enable **Required reviewers**
4. Add yourself (or your team) as a required reviewer
5. Click **Save protection rules**

---

## Part 7 — Apply Configuration and First Deploy

If you completed Part 0, `scripts/configure.py` already stamped all real values into the k8s files. Verify and commit them now.

### Step 7.1 — Verify configure.py has run

```bash
# Should show your real values, not placeholders
grep -E "newName|repoURL|host:" \
  k8s/overlays/prod/kustomization.yaml \
  k8s/argocd/application.yaml \
  k8s/base/ingress/ingress.yaml
```

If you see `ACCOUNT_ID`, `YOUR_GITHUB_USERNAME`, or `YOUR_DOMAIN_HERE`, re-run the configure script:

```bash
python scripts/configure.py
```

### Step 7.2 — Commit and push the configured k8s files

```bash
git add k8s/overlays/prod/kustomization.yaml \
        k8s/argocd/application.yaml \
        k8s/base/ingress/ingress.yaml
git commit -m "chore: configure k8s manifests for deployment"
git push origin main
```

This push triggers the CI/CD pipeline (Stage 0→3). After you approve the production gate (Part 8, Step 8.3), Stage 4 will run `kustomize edit set image` inside `k8s/overlays/prod/` and commit the real ECR image reference with the SHA tag.

> **Note:** `terraform.tfvars` is gitignored — do not add it to the commit.

---

## Part 8 — First Deployment

### Step 8.1 — Apply the ArgoCD Application manifest

`eks_bootstrap.py` Phase 5 applies this automatically. To apply it manually:

```bash
kubectl apply -f k8s/argocd/application.yaml

# Verify the Application was created
kubectl get application -n argocd
# NAME        SYNC STATUS   HEALTH STATUS
# bookstore   OutOfSync     Missing
```

It will show `OutOfSync` until ArgoCD performs the first sync, which happens automatically within 3 minutes. You can trigger it immediately:

```bash
argocd app sync bookstore --prune
```

### Step 8.2 — Trigger the CI/CD pipeline

Push any change to the `main` branch (the commit from Step 7.2 already did this). The pipeline will now run through all 4 stages:

```
Stage 0: Secret Scan     → ~30 seconds
Stage 1: SAST + Tests    → ~3 minutes (runs vitest tests first, then npm audit)
Stage 2: Validate        → ~2 minutes
Stage 3: Build→Scan→Push → ~5–8 minutes (parallel with Stage 2)
Stage 4: Deploy          → awaiting manual approval
```

Monitor at: `https://github.com/$GITHUB_REPO/actions` (your repo from `config.env`)

### Step 8.3 — Approve the production deployment

When Stage 3 finishes, GitHub will pause and send a notification to the required reviewers. To approve:

1. Go to the Actions run
2. Click **Review deployments**
3. Check **production**
4. Click **Approve and deploy**

Stage 4 runs and commits the new image tags to `k8s/overlays/prod/kustomization.yaml`.

### Step 8.4 — Watch ArgoCD sync

```bash
# Watch the sync status
kubectl get application bookstore -n argocd --watch

# Or use the CLI
argocd app get bookstore

# Check the pods coming up
kubectl get pods -n bookstore --watch
# NAME                        READY   STATUS              RESTARTS
# backend-xxx                 0/1     ContainerCreating   0
# frontend-xxx                0/1     ContainerCreating   0
# mysql-0                     0/1     ContainerCreating   0
# ...
# backend-xxx                 1/1     Running             0
# frontend-xxx                1/1     Running             0
# mysql-0                     1/1     Running             0
```

The backend uses an Argo Rollout with a canary strategy (10% → 50% → 100%). Watch canary progress:

```bash
kubectl argo rollouts get rollout backend -n bookstore --watch
```

All pods should reach `Running` status within 3–5 minutes.

---

## Part 9 — DNS and TLS Configuration

### Step 9.1 — Get the Nginx Ingress LoadBalancer hostname

`eks_bootstrap.py` Phase 8 prints this value. To retrieve it manually:

```bash
kubectl get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
# abc123.us-west-1.elb.amazonaws.com
```

### Step 9.2 — Create DNS records

In Route 53 (or your DNS provider), create two **CNAME** records pointing to the NLB hostname from Step 9.1:

| Name | Type | Value |
|---|---|---|
| `bookstore.<YOUR_DOMAIN>` | CNAME | NLB hostname from Step 9.1 |
| `api.bookstore.<YOUR_DOMAIN>` | CNAME | same NLB hostname |

With Route 53 you can also use **Alias** records, which are free for AWS resources:

```bash
# Source config.env so DOMAIN is available
source config.env

# Get the hosted zone ID for your domain
ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name $DOMAIN \
  --query "HostedZones[0].Id" --output text | sed 's|/hostedzone/||')

# NLB hostname from Step 9.1
ELB_HOSTNAME="<nlb-hostname>.us-west-1.elb.amazonaws.com"   # replace with actual value

aws route53 change-resource-record-sets \
  --hosted-zone-id "$ZONE_ID" \
  --change-batch "{
    \"Changes\": [
      {
        \"Action\": \"UPSERT\",
        \"ResourceRecordSet\": {
          \"Name\": \"bookstore.$DOMAIN\",
          \"Type\": \"CNAME\",
          \"TTL\": 300,
          \"ResourceRecords\": [{\"Value\": \"$ELB_HOSTNAME\"}]
        }
      },
      {
        \"Action\": \"UPSERT\",
        \"ResourceRecordSet\": {
          \"Name\": \"api.bookstore.$DOMAIN\",
          \"Type\": \"CNAME\",
          \"TTL\": 300,
          \"ResourceRecords\": [{\"Value\": \"$ELB_HOSTNAME\"}]
        }
      }
    ]
  }"
```

### Step 9.3 — Verify TLS certificate issuance

cert-manager automatically requests a Let's Encrypt certificate when the Ingress is created. This takes 2–5 minutes after DNS propagates.

```bash
kubectl get certificate -n bookstore
# NAME            READY   SECRET          AGE
# bookstore-tls   True    bookstore-tls   5m

# If it is not Ready after 10 minutes, check the challenge:
kubectl describe challenge -n bookstore
```

---

## Part 10 — Verify the Application

### Step 10.1 — Check all pods are healthy

```bash
kubectl get pods -n bookstore
# NAME                        READY   STATUS    RESTARTS   AGE
# frontend-xxx-yyy            1/1     Running   0          10m
# backend-xxx-yyy             1/1     Running   0          10m
# mysql-0                     1/1     Running   0          10m

# Backend runs as an Argo Rollout, not a plain Deployment:
kubectl argo rollouts get rollout backend -n bookstore

kubectl get hpa -n bookstore
# NAME           REFERENCE                           TARGETS         MINPODS   MAXPODS
# backend-hpa    Rollout/backend                     cpu: 5%/70%     1         5
# frontend-hpa   Deployment/frontend                 cpu: 2%/70%     1         3
```

### Step 10.2 — Verify secret sync

```bash
kubectl get externalsecret -n bookstore
# NAME        STORE                REFRESH INTERVAL   STATUS   READY
# db-secret   aws-secretsmanager   1h                 Ready    True

kubectl get secret db-secret -n bookstore
# NAME        TYPE     DATA   AGE
# db-secret   Opaque   2      10m
# (Data: 2 keys — DB_USERNAME and DB_PASSWORD, fetched from Secrets Manager)
```

### Step 10.3 — Test the application endpoints

```bash
# Source config.env so DOMAIN is available
source config.env

# Frontend
curl -I https://bookstore.$DOMAIN
# HTTP/2 200
# server: nginx

# Backend API
curl https://api.bookstore.$DOMAIN/books
# [{"id":1,"title":"..."},...]

# Metrics endpoint (Prometheus scrapes this)
curl https://api.bookstore.$DOMAIN/metrics
# # HELP http_requests_total Total HTTP requests
# ...

# HTTP redirect (must return 301/302 to HTTPS)
curl -I http://bookstore.$DOMAIN
# HTTP/1.1 308 Permanent Redirect
# location: https://bookstore.$DOMAIN/
```

### Step 10.4 — Verify ArgoCD shows healthy

```bash
argocd app get bookstore
# Name:               bookstore
# Sync Status:        Synced
# Health Status:      Healthy
```

### Step 10.5 — Access Grafana dashboards (optional)

```bash
kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80
# Open http://localhost:3000
# Default credentials: admin / prom-operator
```

Grafana includes pre-built Kubernetes dashboards. The backend exposes `http_requests_total` and `http_request_duration_seconds` metrics that Prometheus scrapes via the `ServiceMonitor` in `k8s/base/monitoring/servicemonitor.yaml`.

### Step 10.6 — Verify the security scan results

In GitHub, go to your repository → **Security** → **Code scanning alerts**. Trivy SARIF results for both images are uploaded here after every build. Any CRITICAL or HIGH CVE that has a fix available will have blocked the push in Stage 3.

---

## Part 11 — Local Development Setup

### Step 11.1 — Backend

```bash
cd backend
npm install

# Create your local environment file
cat > .env << EOF
DB_HOST=localhost
DB_USERNAME=root
DB_PASSWORD=yourpassword
DB_PORT=3306
DB_NAME=test
APP_PORT=3000
EOF

# Seed the database schema (requires local MySQL running)
# The init SQL is in k8s/base/database/mysql-init-configmap.yaml — copy the SQL block and run:
mysql -u root -p -e "
  CREATE DATABASE IF NOT EXISTS test;
  USE test;
  CREATE TABLE IF NOT EXISTS books (
    id INT NOT NULL AUTO_INCREMENT,
    title VARCHAR(300) NOT NULL,
    \`desc\` VARCHAR(500) NOT NULL,
    price FLOAT NOT NULL,
    cover VARCHAR(500) NOT NULL,
    PRIMARY KEY (id)
  );"

# Start the server
node index.js
# Connected to backend on port 3000.
```

### Step 11.2 — Run backend tests

```bash
cd backend
npm test
# Runs 6 vitest tests using a vi.fn() mock db — no real database needed.
# Tests cover: GET /, GET /books, POST /books, DELETE /books/:id, PUT /books/:id
```

### Step 11.3 — Frontend

```bash
cd client
npm install

# Point the frontend at your local backend
# Edit src/pages/config.js:
#   const API_BASE_URL = "http://localhost:3000";

npm start
# Local: http://localhost:3001
```

### Step 11.4 — Build and push images manually (optional)

Use this only for hotfixes or pre-release testing. The pipeline does this automatically:

```bash
# Load your values from config.env first
source config.env

chmod +x scripts/build-and-push.sh
./scripts/build-and-push.sh \
  $AWS_ACCOUNT_ID \
  $AWS_REGION \
  v1.0.0-hotfix \
  https://api.bookstore.$DOMAIN
```

---

## Troubleshooting

### Pods stuck in `Pending` (PVC not bound)

```bash
kubectl describe pod mysql-0 -n bookstore
# Look for: "waiting for volume"

kubectl get pvc -n bookstore
# If STATUS is Pending, the gp3 StorageClass may not exist:
kubectl get storageclass
# The gp3 StorageClass is deployed by ArgoCD from k8s/base/storageclass/gp3.yaml
# If it is missing, verify ArgoCD has synced successfully
```

### `ImagePullBackOff` on backend or frontend pods

```bash
kubectl describe pod <pod-name> -n bookstore
# Look for: "Failed to pull image"
# Cause: node group IAM role lacks ECR read permission
# Fix: verify AmazonEC2ContainerRegistryReadOnly is attached to the node group role
aws iam list-attached-role-policies --role-name bookstore-eks-node-role
```

### ArgoCD stuck in `OutOfSync`

```bash
argocd app diff bookstore
# Shows what differs between git and the cluster

# Force a refresh and sync
argocd app sync bookstore --force --prune
```

### ESO ExternalSecret shows `SecretSyncedError`

```bash
kubectl describe externalsecret db-secret -n bookstore
# Common causes:
# 1. Secret /bookstore/db-credentials does not exist in Secrets Manager
#    → Re-run Step 5.1
# 2. IRSA role lacks secretsmanager:GetSecretValue permission
#    → Verify the IAM role policy (created by eks_bootstrap.py Phase 3)
# 3. Service account annotation incorrect
#    → kubectl describe sa external-secrets-sa -n external-secrets
```

### GitHub Actions OIDC auth fails

```bash
# Error: "Could not assume role"
# Verify:
# 1. The OIDC provider is registered in IAM for your account
# 2. The IAM role trust policy sub condition matches your GITHUB_REPO exactly
#    (check: aws iam get-role --role-name bookstore-github-oidc-role --query Role.AssumeRolePolicyDocument)
# 3. AWS_ROLE_ARN secret in GitHub matches the role ARN exactly
```

### cert-manager certificate stays `False`

```bash
kubectl describe certificaterequest -n bookstore
# Common cause: HTTP-01 challenge cannot reach the domain
# Let's Encrypt must be able to hit http://bookstore.<YOUR_DOMAIN>/.well-known/acme-challenge/
# Verify DNS records are propagated: dig bookstore.<YOUR_DOMAIN>
# Verify port 80 is open on the Nginx Ingress LoadBalancer security group
```

### Terraform state lock not releasing

```bash
# If a previous apply was interrupted, the DynamoDB lock may remain
terraform force-unlock <LOCK_ID>
# LOCK_ID appears in the error message when you run terraform plan/apply
```

### Argo Rollout canary stuck

```bash
kubectl argo rollouts get rollout backend -n bookstore
# If the rollout is paused at a step, promote it manually:
kubectl argo rollouts promote backend -n bookstore
# Or abort and roll back:
kubectl argo rollouts abort backend -n bookstore
```

---

## Summary — Component Ownership

| Component | Managed by | Config location |
|---|---|---|
| VPC, subnets, NAT, IGW | Terraform | `modules/network/` |
| Security groups (ALB ingress + RDS) | Terraform | `modules/security/` |
| ACM certificate | Terraform | `modules/acm/` |
| RDS MySQL | Terraform | `modules/rds/` |
| ECR repositories | Terraform | `modules/ecr/` |
| EKS cluster + nodes | Terraform | `modules/eks/` |
| Route 53 (private RDS zone) | Terraform | `modules/route53/` |
| EBS CSI driver | Terraform (`aws_eks_addon`) | `modules/eks-addons/` |
| gp3 StorageClass | ArgoCD (Kustomize base) | `k8s/base/storageclass/gp3.yaml` |
| cert-manager | Terraform (Helm) | `modules/eks-addons/` |
| External Secrets Operator | Terraform (Helm) | `modules/eks-addons/` |
| Nginx Ingress | Terraform (Helm) | `modules/eks-addons/` |
| ArgoCD | Terraform (Helm) | `modules/eks-addons/` |
| Prometheus + Grafana | Terraform (Helm) | `modules/eks-addons/` |
| Argo Rollouts | Terraform (Helm) | `modules/eks-addons/` |
| ClusterIssuer | `eks_bootstrap.py` Phase 2 | `cluster-issuer.yaml` |
| IRSA for ESO | `eks_bootstrap.py` Phase 3 | (created via AWS CLI) |
| DB credentials | AWS Secrets Manager | `eks_bootstrap.py` Phase 4 |
| ArgoCD Application | `eks_bootstrap.py` Phase 5 | `k8s/argocd/application.yaml` |
| k8s base manifests | ArgoCD + Kustomize | `k8s/base/` |
| k8s prod overlay (image tags, HPAs) | ArgoCD + CI/CD | `k8s/overlays/prod/` |
| Docker images | GitHub Actions | `.github/workflows/ci-cd.yml` |
