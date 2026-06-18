# Bookstore — Complete Implementation Guide

This guide walks you through standing up the entire Bookstore application from zero: a three-tier architecture on AWS with Terraform-managed infrastructure, containerised workloads on EKS, GitOps delivery via ArgoCD, and a DevSecOps CI/CD pipeline on GitHub Actions.

Follow every part in order on a first deployment. After initial setup, only Parts 7–9 are repeated for each new release.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites](#2-prerequisites)
3. [Part 1 — AWS Account Setup](#part-1--aws-account-setup)
4. [Part 2 — Bootstrap Terraform Remote State](#part-2--bootstrap-terraform-remote-state)
5. [Part 3 — Provision Infrastructure with Terraform](#part-3--provision-infrastructure-with-terraform)
6. [Part 4 — Configure kubectl and Install EKS Add-ons](#part-4--configure-kubectl-and-install-eks-add-ons)
7. [Part 5 — Install ArgoCD](#part-5--install-argocd)
8. [Part 6 — Configure Secret Management](#part-6--configure-secret-management)
9. [Part 7 — GitHub Repository Setup](#part-7--github-repository-setup)
10. [Part 8 — Update Repository Placeholders](#part-8--update-repository-placeholders)
11. [Part 9 — First Deployment](#part-9--first-deployment)
12. [Part 10 — DNS and TLS Configuration](#part-10--dns-and-tls-configuration)
13. [Part 11 — Verify the Application](#part-11--verify-the-application)
14. [Part 12 — Local Development Setup](#part-12--local-development-setup)
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
│   │  │   us-west-1a (170.20.1.0/24)    us-west-1b (170.20.2.0/24)      │   │   │
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
│   │  │   us-west-1a (170.20.3.0/24)    us-west-1b (170.20.4.0/24)      │   │   │
│   │  │   ┌──────────────────────────────────────────────────────────┐   │   │   │
│   │  │   │  EKS Managed Node Group  (t3.medium × 1–4 nodes)         │   │   │   │
│   │  │   │                                                          │   │   │   │
│   │  │   │  bookstore namespace                                     │   │   │   │
│   │  │   │  ┌────────────────┐  ┌─────────────────┐                │   │   │   │
│   │  │   │  │ Frontend Pods  │  │  Backend Pods    │                │   │   │   │
│   │  │   │  │ React / Nginx  │  │  Node.js/Express │                │   │   │   │
│   │  │   │  │ replicas: 2    │  │  replicas: 2     │                │   │   │   │
│   │  │   │  └────────────────┘  └─────────────────┘                │   │   │   │
│   │  │   │         ▲                    │                           │   │   │   │
│   │  │   │  Nginx Ingress          MySQL StatefulSet                │   │   │   │
│   │  │   │  (ingress-nginx ns)     (dev / local only)              │   │   │   │
│   │  │   │                              │ in prod → RDS             │   │   │   │
│   │  │   └──────────────────────────────────────────────────────────┘   │   │   │
│   │  │                                  │                                │   │   │
│   │  │   us-west-1a (170.20.5–6.0/24)  (170.20.6.0/24)                  │   │   │
│   │  └──────────────────────────────────────────────────────────────────┘   │   │
│   │                                                                         │   │
│   │  ┌──────────────────────────────────────────────────────────────────┐   │   │
│   │  │  Private Subnets — Data Tier                                     │   │   │
│   │  │                                                                  │   │   │
│   │  │   us-west-1a (170.20.7.0/24)    us-west-1b (170.20.8.0/24)      │   │   │
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
│                                                                        │
│  Stage 0: Secret Scan      Stage 1: SAST              Stage 2: Lint   │
│  ┌─────────────────────┐   ┌──────────────────────┐   ┌────────────┐  │
│  │  Gitleaks           │   │  Semgrep (OWASP)     │   │  ESLint    │  │
│  │  Full git history   │ → │  npm audit (high+)   │   │  kubeval   │  │
│  └─────────────────────┘   └──────────────────────┘   └────────────┘  │
│                                    │                         │         │
│                                    └──────────┬──────────────┘         │
│                                               ▼                        │
│                              Stage 3: Build → Scan → Push              │
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
│                              │  kustomize edit set image            │  │
│                              │  git commit k8s/kustomization.yaml   │  │
│                              │  git push (GITHUB_TOKEN)             │  │
│                              └──────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────────┘
                                               │
                                               ▼ (commit detected, ~3 min)
┌────────────────────────────────────────────────────────────────────────┐
│  ArgoCD (running in EKS, argocd namespace)                             │
│                                                                        │
│  Polls GitHub repo → detects new commit in k8s/kustomization.yaml     │
│  Runs: kustomize build k8s/                                            │
│  Applies diff to bookstore namespace                                   │
│  Pods rolling-restart with new ECR image                               │
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
- A **registered domain name** (this project uses `b17facebook.xyz`) with Route 53 as the DNS provider, or the ability to add DNS records wherever your domain is hosted

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

**2. Create the trust policy file. Replace `YOUR_ORG` and `YOUR_REPO`:**

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
          "token.actions.githubusercontent.com:sub": "repo:YOUR_ORG/YOUR_REPO:*"
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

### Step 2.2 — Update main.tf with your account ID

Open `main.tf` and replace the `ACCOUNT_ID` placeholder in the backend block with your 12-digit account ID printed by the script:

```hcl
backend "s3" {
  bucket         = "bookstore-terraform-state-123456789012"   # ← your actual account ID
  key            = "prod/terraform.tfstate"
  region         = "us-west-1"
  dynamodb_table = "terraform-state-lock"
  encrypt        = true
}
```

> **Important:** Do this substitution exactly once. Every subsequent `terraform init` and `terraform apply` will reuse the same S3 object. The state file is never recreated.

---

## Part 3 — Provision Infrastructure with Terraform

Terraform provisions the entire AWS foundation: VPC, subnets, security groups, ACM certificate, RDS, ECR repositories, EKS cluster, and private DNS for RDS.

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
Terraform has been successfully initialized!
```

### Step 3.2 — Preview the plan

```bash
terraform plan
```

Review the plan output. Terraform will create approximately 40–50 resources. Look for any unexpected `destroy` actions — there should be none on a fresh account.

### Step 3.3 — Apply

```bash
terraform apply
```

Type `yes` when prompted. This takes **15–25 minutes** because:
- EKS control plane provisioning takes 10–12 minutes
- RDS Multi-AZ instance takes 5–8 minutes

### Step 3.4 — Capture outputs

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

## Part 4 — Configure kubectl and Install EKS Add-ons

EKS needs four cluster add-ons that are not managed by Terraform: the EBS CSI driver (for persistent volumes), cert-manager (TLS), External Secrets Operator (secret sync), and Nginx Ingress.

### Step 4.1 — Configure kubectl

```bash
aws eks update-kubeconfig \
  --name bookstore-eks \
  --region us-west-1

# Verify the cluster is reachable
kubectl get nodes
# NAME                          STATUS   ROLES    AGE
# ip-170-20-3-xx.ec2.internal   Ready    <none>   5m
```

All nodes should be in `Ready` status before continuing.

---

### Step 4.2 — Install the EBS CSI Driver

The EBS CSI driver allows Kubernetes to dynamically provision EBS volumes for the MySQL StatefulSet PVC (`storageClassName: gp3`).

```bash
aws eks create-addon \
  --cluster-name bookstore-eks \
  --addon-name aws-ebs-csi-driver \
  --region us-west-1

# Wait for the add-on to be Active
aws eks wait addon-active \
  --cluster-name bookstore-eks \
  --addon-name aws-ebs-csi-driver \
  --region us-west-1

echo "EBS CSI driver is active."
```

**Create the gp3 StorageClass** (EKS does not create this by default):

```bash
kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
EOF

kubectl get storageclass
# NAME            PROVISIONER       RECLAIMPOLICY   VOLUMEBINDINGMODE      ...
# gp3 (default)   ebs.csi.aws.com   Retain          WaitForFirstConsumer   ...
```

---

### Step 4.3 — Install cert-manager

cert-manager issues and renews TLS certificates from Let's Encrypt for the `bookstore.b17facebook.xyz` and `api.bookstore.b17facebook.xyz` domains.

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.14.4 \
  --set installCRDs=true

# Wait for pods to be ready
kubectl wait pods -n cert-manager \
  --all --for=condition=Ready --timeout=120s
```

**Create the Let's Encrypt ClusterIssuer:**

```bash
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: your-email@example.com        # replace with your email
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - http01:
          ingress:
            class: nginx
EOF
```

---

### Step 4.4 — Install External Secrets Operator

ESO syncs the database credentials from AWS Secrets Manager into a native Kubernetes Secret inside the cluster. No credentials ever pass through the pipeline or live in git.

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

helm install external-secrets external-secrets/external-secrets \
  --namespace external-secrets \
  --create-namespace \
  --version 0.9.13

kubectl wait pods -n external-secrets \
  --all --for=condition=Ready --timeout=120s
```

**Create the IRSA service account for ESO.** ESO needs an IAM role that can read from Secrets Manager. Replace `OIDC_PROVIDER_ID` with the ID portion of the OIDC provider ARN from `terraform output eks_oidc_provider_arn`:

```bash
# Get the OIDC provider ID (everything after the last slash)
OIDC_ID=$(aws eks describe-cluster \
  --name bookstore-eks \
  --query "cluster.identity.oidc.issuer" \
  --output text | sed 's|.*/||')

# Create the trust policy
cat > /tmp/eso-trust.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}:sub":
          "system:serviceaccount:external-secrets:external-secrets-sa",
        "oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}:aud":
          "sts.amazonaws.com"
      }
    }
  }]
}
EOF

# Create the IAM role
aws iam create-role \
  --role-name bookstore-eso-role \
  --assume-role-policy-document file:///tmp/eso-trust.json

# Attach Secrets Manager read policy
aws iam put-role-policy \
  --role-name bookstore-eso-role \
  --policy-name bookstore-eso-policy \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": "arn:aws:secretsmanager:us-west-1:'${ACCOUNT_ID}':secret:/bookstore/db-credentials*"
    }]
  }'

ESO_ROLE_ARN=$(aws iam get-role \
  --role-name bookstore-eso-role \
  --query "Role.Arn" --output text)

# Create the annotated service account in the cluster
kubectl create namespace bookstore --dry-run=client -o yaml | kubectl apply -f -

kubectl create serviceaccount external-secrets-sa \
  --namespace external-secrets \
  --dry-run=client -o yaml \
  | kubectl annotate --local -f - \
    eks.amazonaws.com/role-arn=${ESO_ROLE_ARN} \
    -o yaml \
  | kubectl apply -f -
```

---

### Step 4.5 — Install Nginx Ingress Controller

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --version 4.9.1 \
  --set controller.service.type=LoadBalancer

# Wait for the LoadBalancer to get an external hostname (~2 min)
kubectl get svc -n ingress-nginx ingress-nginx-controller --watch
# NAME                       TYPE           CLUSTER-IP    EXTERNAL-IP           PORT(S)
# ingress-nginx-controller   LoadBalancer   10.100.x.x    abc.elb.amazonaws.com   80:...,443:...
```

Note the `EXTERNAL-IP` value (an AWS ELB hostname) — you will need it for DNS in Part 10.

---

## Part 5 — Install ArgoCD

ArgoCD is the GitOps engine. It watches the `k8s/` directory in your GitHub repository and reconciles the cluster state to match what is in git.

### Step 5.1 — Install ArgoCD

```bash
kubectl create namespace argocd

kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for all ArgoCD pods to be ready (~3 min)
kubectl wait pods -n argocd \
  --all --for=condition=Ready --timeout=300s

kubectl get pods -n argocd
# NAME                                       READY   STATUS    RESTARTS
# argocd-application-controller-0            1/1     Running   0
# argocd-dex-server-xxx                      1/1     Running   0
# argocd-redis-xxx                           1/1     Running   0
# argocd-repo-server-xxx                     1/1     Running   0
# argocd-server-xxx                          1/1     Running   0
```

### Step 5.2 — Access the ArgoCD UI (optional)

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

### Step 5.3 — Connect your GitHub repository to ArgoCD

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
argocd repo add https://github.com/YOUR_ORG/YOUR_REPO \
  --username YOUR_GITHUB_USERNAME \
  --password YOUR_GITHUB_PAT
```

---

## Part 6 — Configure Secret Management

Database credentials live only in AWS Secrets Manager. ESO reads them and creates an in-cluster Kubernetes Secret. Nothing touches the pipeline or git.

### Step 6.1 — Store DB credentials in Secrets Manager

Choose a strong password. Replace `<strong-password>` below:

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

## Part 7 — GitHub Repository Setup

### Step 7.1 — Create GitHub Actions secrets

Go to your GitHub repository → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**.

Create each secret:

| Secret name | Value | Description |
|---|---|---|
| `AWS_ACCOUNT_ID` | `123456789012` | Your 12-digit AWS account ID |
| `AWS_ROLE_ARN` | `arn:aws:iam::123456789012:role/bookstore-github-oidc-role` | OIDC role ARN from Step 1.2 |
| `API_URL` | `https://api.bookstore.b17facebook.xyz` | Backend API URL injected into the React build |
| `SEMGREP_APP_TOKEN` | *(optional)* | Semgrep Cloud token. If you don't have one, remove the `SEMGREP_APP_TOKEN` env line from `.github/workflows/ci-cd.yml` |

### Step 7.2 — Create the production GitHub Environment

The pipeline requires a manual approval gate before deploying. This is enforced through a GitHub Environment.

1. Go to your repository → **Settings** → **Environments** → **New environment**
2. Name it exactly: `production`
3. Under **Deployment protection rules**, enable **Required reviewers**
4. Add yourself (or your team) as a required reviewer
5. Click **Save protection rules**

---

## Part 8 — Update Repository Placeholders

Two files contain `ACCOUNT_ID` placeholders that must be replaced with your real account ID.

### Step 8.1 — Update k8s/kustomization.yaml

Open `k8s/kustomization.yaml` and replace both `ACCOUNT_ID` occurrences in the `images:` section:

```yaml
images:
  - name: bookstore-backend
    newName: 123456789012.dkr.ecr.us-west-1.amazonaws.com/bookstore-backend
    newTag: latest
  - name: bookstore-frontend
    newName: 123456789012.dkr.ecr.us-west-1.amazonaws.com/bookstore-frontend
    newTag: latest
```

### Step 8.2 — Update k8s/argocd/application.yaml

Open `k8s/argocd/application.yaml` and replace `YOUR_ORG/YOUR_REPO` with your actual GitHub repository URL:

```yaml
source:
  repoURL: https://github.com/your-org/your-repo   # ← your actual repo
  targetRevision: main
  path: k8s
```

### Step 8.3 — Commit and push the changes

```bash
git add k8s/kustomization.yaml k8s/argocd/application.yaml main.tf
git commit -m "config: set account ID and repo URL placeholders"
git push origin main
```

---

## Part 9 — First Deployment

### Step 9.1 — Apply the ArgoCD Application manifest

This registers the bookstore application with ArgoCD. Do this once:

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

### Step 9.2 — Trigger the CI/CD pipeline

Push any change to the `main` branch (the commit from Step 8.3 already did this). The pipeline will now run through all 4 stages:

```
Stage 0: Secret Scan     → ~30 seconds
Stage 1: SAST            → ~3 minutes
Stage 2: Validate        → ~2 minutes
Stage 3: Build→Scan→Push → ~5–8 minutes (parallel with Stage 2)
Stage 4: Deploy          → awaiting manual approval
```

Monitor at: `https://github.com/YOUR_ORG/YOUR_REPO/actions`

### Step 9.3 — Approve the production deployment

When Stage 3 finishes, GitHub will pause and send a notification to the required reviewers. To approve:

1. Go to the Actions run
2. Click **Review deployments**
3. Check **production**
4. Click **Approve and deploy**

Stage 4 runs and commits the new image tags to `k8s/kustomization.yaml`.

### Step 9.4 — Watch ArgoCD sync

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

All pods should reach `Running` status within 3–5 minutes.

---

## Part 10 — DNS and TLS Configuration

### Step 10.1 — Get the Nginx Ingress LoadBalancer hostname

```bash
kubectl get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
# abc123.us-west-1.elb.amazonaws.com
```

### Step 10.2 — Create DNS records

In Route 53 (or your DNS provider), create two **CNAME** records:

| Name | Type | Value |
|---|---|---|
| `bookstore.b17facebook.xyz` | CNAME | `abc123.us-west-1.elb.amazonaws.com` |
| `api.bookstore.b17facebook.xyz` | CNAME | `abc123.us-west-1.elb.amazonaws.com` |

With Route 53 you can also use **Alias** records, which are free for AWS resources:

```bash
# Get the hosted zone ID for your domain
ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name b17facebook.xyz \
  --query "HostedZones[0].Id" --output text | sed 's|/hostedzone/||')

# Get the ELB hosted zone ID (us-west-1 ALB zone)
ELB_HOSTNAME="abc123.us-west-1.elb.amazonaws.com"   # replace with actual value

aws route53 change-resource-record-sets \
  --hosted-zone-id "$ZONE_ID" \
  --change-batch '{
    "Changes": [
      {
        "Action": "UPSERT",
        "ResourceRecordSet": {
          "Name": "bookstore.b17facebook.xyz",
          "Type": "CNAME",
          "TTL": 300,
          "ResourceRecords": [{"Value": "'"$ELB_HOSTNAME"'"}]
        }
      },
      {
        "Action": "UPSERT",
        "ResourceRecordSet": {
          "Name": "api.bookstore.b17facebook.xyz",
          "Type": "CNAME",
          "TTL": 300,
          "ResourceRecords": [{"Value": "'"$ELB_HOSTNAME"'"}]
        }
      }
    ]
  }'
```

### Step 10.3 — Verify TLS certificate issuance

cert-manager automatically requests a Let's Encrypt certificate when the Ingress is created. This takes 2–5 minutes after DNS propagates.

```bash
kubectl get certificate -n bookstore
# NAME            READY   SECRET          AGE
# bookstore-tls   True    bookstore-tls   5m

# If it is not Ready after 10 minutes, check the challenge:
kubectl describe challenge -n bookstore
```

---

## Part 11 — Verify the Application

### Step 11.1 — Check all pods are healthy

```bash
kubectl get pods -n bookstore
# NAME                        READY   STATUS    RESTARTS   AGE
# frontend-xxx-yyy            1/1     Running   0          10m
# frontend-xxx-zzz            1/1     Running   0          10m
# backend-xxx-yyy             1/1     Running   0          10m
# backend-xxx-zzz             1/1     Running   0          10m
# mysql-0                     1/1     Running   0          10m

kubectl get hpa -n bookstore
# NAME       REFERENCE             TARGETS         MINPODS   MAXPODS
# backend    Deployment/backend    cpu: 5%/70%     2         5
# frontend   Deployment/frontend   cpu: 2%/70%     2         5
```

### Step 11.2 — Verify secret sync

```bash
kubectl get externalsecret -n bookstore
# NAME        STORE                REFRESH INTERVAL   STATUS   READY
# db-secret   aws-secretsmanager   1h                 Ready    True

kubectl get secret db-secret -n bookstore
# NAME        TYPE     DATA   AGE
# db-secret   Opaque   2      10m
# (Data: 2 keys — DB_USERNAME and DB_PASSWORD, fetched from Secrets Manager)
```

### Step 11.3 — Test the application endpoints

```bash
# Frontend
curl -I https://bookstore.b17facebook.xyz
# HTTP/2 200
# server: nginx

# Backend API
curl https://api.bookstore.b17facebook.xyz/books
# [{"id":1,"title":"..."},...]

# HTTP redirect (must return 301/302 to HTTPS)
curl -I http://bookstore.b17facebook.xyz
# HTTP/1.1 308 Permanent Redirect
# location: https://bookstore.b17facebook.xyz/
```

### Step 11.4 — Verify ArgoCD shows healthy

```bash
argocd app get bookstore
# Name:               bookstore
# Sync Status:        Synced
# Health Status:      Healthy
```

### Step 11.5 — Verify the security scan results

In GitHub, go to your repository → **Security** → **Code scanning alerts**. Trivy SARIF results for both images are uploaded here after every build. Any CRITICAL or HIGH CVE that has a fix available will have blocked the push in Stage 3.

---

## Part 12 — Local Development Setup

### Step 12.1 — Backend

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

# Seed the database schema (requires local MySQL)
mysql -u root -p < test.sql

# Start the server
node index.js
# Server running on port 3000
```

### Step 12.2 — Frontend

```bash
cd client
npm install

# Point the frontend at your local backend
# Edit src/pages/config.js:
#   const API_BASE_URL = "http://localhost:3000";

npm start
# Local: http://localhost:3001
```

### Step 12.3 — Build and push images manually (optional)

Use this only for hotfixes or pre-release testing. The pipeline does this automatically:

```bash
chmod +x scripts/build-and-push.sh
./scripts/build-and-push.sh \
  123456789012 \
  us-west-1 \
  v1.0.0-hotfix \
  https://api.bookstore.b17facebook.xyz
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
# Re-run the StorageClass creation from Step 4.2
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
#    → Re-run Step 6.1
# 2. IRSA role lacks secretsmanager:GetSecretValue permission
#    → Verify the IAM role policy from Step 4.4
# 3. Service account annotation incorrect
#    → kubectl describe sa external-secrets-sa -n external-secrets
```

### GitHub Actions OIDC auth fails

```bash
# Error: "Could not assume role"
# Verify:
# 1. The OIDC provider is registered in IAM for your account
# 2. The trust policy contains YOUR_ORG/YOUR_REPO (exact match)
# 3. AWS_ROLE_ARN secret in GitHub matches the role ARN exactly
```

### cert-manager certificate stays `False`

```bash
kubectl describe certificaterequest -n bookstore
# Common cause: HTTP-01 challenge cannot reach the domain
# Let's Encrypt must be able to hit http://bookstore.b17facebook.xyz/.well-known/acme-challenge/
# Verify DNS records are propagated: dig bookstore.b17facebook.xyz
# Verify port 80 is open on the Nginx Ingress LoadBalancer security group
```

### Terraform state lock not releasing

```bash
# If a previous apply was interrupted, the DynamoDB lock may remain
terraform force-unlock <LOCK_ID>
# LOCK_ID appears in the error message when you run terraform plan/apply
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
| EBS CSI driver | `aws eks create-addon` | Part 4.2 (one-time) |
| gp3 StorageClass | `kubectl apply` | Part 4.2 (one-time) |
| cert-manager | Helm | Part 4.3 (one-time) |
| External Secrets Operator | Helm | Part 4.4 (one-time) |
| Nginx Ingress | Helm | Part 4.5 (one-time) |
| ArgoCD | `kubectl apply` | Part 5 (one-time) |
| DB credentials | AWS Secrets Manager | Part 6.1 (one-time) |
| k8s manifests + image tags | ArgoCD + CI/CD | `k8s/` (per release) |
| Docker images | GitHub Actions | `.github/workflows/ci-cd.yml` |
