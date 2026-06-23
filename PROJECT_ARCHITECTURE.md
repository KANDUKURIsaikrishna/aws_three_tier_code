# Bookstore — Complete Project Architecture & Implementation Guide

**Stack:** React · Node.js · MySQL · Kubernetes (EKS) · Terraform · GitHub Actions · ArgoCD  
**Domain:** `b17facebook.xyz` · **Region:** `us-west-1`

---

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [Architecture Overview](#2-architecture-overview)
3. [AWS Infrastructure](#3-aws-infrastructure)
4. [Networking Deep Dive](#4-networking-deep-dive)
5. [Kubernetes Architecture](#5-kubernetes-architecture)
6. [Secrets Management](#6-secrets-management)
7. [CI/CD Pipeline](#7-cicd-pipeline)
8. [GitOps with ArgoCD](#8-gitops-with-argocd)
9. [Complete File Structure](#9-complete-file-structure)
10. [Implementation Guide](#10-implementation-guide)

---

## 1. Project Overview

A full-stack bookstore web application deployed on AWS using a classic three-tier architecture — presentation, application, and data tiers — running entirely on Kubernetes with production-grade security and automation.

| Tier | Component | Technology |
|------|-----------|------------|
| Presentation | React SPA served by nginx | `client/` |
| Application | REST API (Express/Node.js) | `backend/` |
| Data | MySQL 8.0 | Kubernetes StatefulSet |

The infrastructure is fully automated: Terraform provisions AWS resources, `eks_bootstrap.py` installs cluster add-ons, and GitHub Actions builds and deploys every commit automatically via ArgoCD.

---

## 2. Architecture Overview

```
Internet
    │
    ▼
Route 53 (Public Hosted Zone: b17facebook.xyz)
    │  bookstore.b17facebook.xyz     → NLB
    │  api.bookstore.b17facebook.xyz → NLB
    ▼
AWS Network Load Balancer (NLB)
    │  Port 80 / 443 (TLS terminated by ingress-nginx)
    ▼
┌─────────────────────────────────────────────────────────────┐
│  VPC  170.20.0.0/16                                         │
│                                                             │
│  Public Subnets (NLB ENIs)                                  │
│  ┌──────────────────┐  ┌──────────────────┐                 │
│  │ 170.20.1.0/24    │  │ 170.20.2.0/24    │                 │
│  │ us-west-1a       │  │ us-west-1c       │                 │
│  └──────────────────┘  └──────────────────┘                 │
│          │                      │                           │
│          └──────────┬───────────┘                           │
│                     ▼                                       │
│  Private Subnets (EKS Nodes)                                │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────┐ ┌────────┐ │
│  │170.20.3.0/24 │ │170.20.4.0/24 │ │170.20.5  │ │170.20.6│ │
│  │ us-west-1a   │ │ us-west-1c   │ │ /24      │ │ /24    │ │
│  └──────┬───────┘ └──────┬───────┘ └────┬─────┘ └───┬────┘ │
│         └────────────────┴──────┬────────┘           │      │
│                                 ▼                    │      │
│              EKS Cluster: bookstore-eks              │      │
│         ┌──────────────────────────────────┐         │      │
│         │  Namespace: bookstore            │         │      │
│         │  ┌──────────┐  ┌─────────────┐  │         │      │
│         │  │ frontend │  │   backend   │  │         │      │
│         │  │ (nginx)  │  │ (Node.js)   │  │         │      │
│         │  │ 2 pods   │  │  2 pods     │  │         │      │
│         │  └──────────┘  └──────┬──────┘  │         │      │
│         │                       │ :3306   │         │      │
│         │              ┌────────▼──────┐  │         │      │
│         │              │  mysql-0      │  │         │      │
│         │              │ (StatefulSet) │  │         │      │
│         │              └───────────────┘  │         │      │
│         └──────────────────────────────────┘         │      │
│                                                      │      │
│  Private Subnets (RDS)                               │      │
│  ┌──────────────────┐  ┌──────────────────┐          │      │
│  │ 170.20.7.0/24    │  │ 170.20.8.0/24    │          │      │
│  │ us-west-1a (RDS) │  │ us-west-1c (RDS) │          │      │
│  └──────────────────┘  └──────────────────┘          │      │
│                                                      │      │
│  NAT Gateway (public-subnet-1) ←── Private → Internet│      │
└─────────────────────────────────────────────────────────────┘

AWS Services (outside VPC)
  ECR       — Docker image registry (bookstore-backend, bookstore-frontend)
  ACM       — TLS certificate for *.b17facebook.xyz
  Secrets Manager — DB credentials at /bookstore/db-credentials
  IAM/OIDC  — Keyless auth for GitHub Actions and ESO (IRSA)
```

---

## 3. AWS Infrastructure

All infrastructure is defined in Terraform (`main.tf` + `modules/`).

### 3.1 VPC — `170.20.0.0/16`

| Subnet | CIDR | AZ | Purpose |
|--------|------|----|---------|
| public-1 | 170.20.1.0/24 | us-west-1a | NLB ENIs, NAT Gateway EIP |
| public-2 | 170.20.2.0/24 | us-west-1c | NLB ENIs |
| private-3 | 170.20.3.0/24 | us-west-1a | EKS worker nodes |
| private-4 | 170.20.4.0/24 | us-west-1c | EKS worker nodes |
| private-5 | 170.20.5.0/24 | us-west-1a | EKS worker nodes |
| private-6 | 170.20.6.0/24 | us-west-1c | EKS worker nodes |
| private-7 | 170.20.7.0/24 | us-west-1a | RDS subnet group |
| private-8 | 170.20.8.0/24 | us-west-1c | RDS subnet group |

- **Internet Gateway** — attached to VPC; public subnets route `0.0.0.0/0` through it
- **NAT Gateway** — in `public-subnet-1`; private subnets route outbound traffic through it (nodes pull images from ECR, contact AWS APIs)
- **DNS** — `enable_dns_support` + `enable_dns_hostnames` enabled so pods can resolve service names

### 3.2 EKS Cluster

| Setting | Value |
|---------|-------|
| Cluster name | `bookstore-eks` |
| Kubernetes version | 1.31 |
| Node type | `t3.medium` |
| Nodes | min 1 / desired 2 / max 4 |
| Node placement | private subnets (3–6) |
| Control plane logs | api, audit, authenticator, controllerManager, scheduler |
| OIDC provider | enabled (required for IRSA) |

**IAM roles created by Terraform:**
- `bookstore-eks-cluster-role` — EKS control plane role
- `bookstore-eks-node-role` — EC2 node role with `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`, `AmazonEC2ContainerRegistryReadOnly`, `AmazonEBSCSIDriverPolicy`

**EKS Add-on:** `aws-ebs-csi-driver` — enables EBS persistent volumes (required for MySQL StatefulSet PVC).

### 3.3 RDS

| Setting | Value |
|---------|-------|
| Engine | MySQL 8.0 |
| Instance | `db.t3.micro` |
| Storage | 25 GB |
| Multi-AZ | Yes |
| Backup retention | 7 days |
| Placement | private-7 + private-8 |
| Access | Security group allows port 3306 from `170.20.0.0/16` only |

> **Note:** RDS is provisioned but **not used by the running app**. The in-cluster MySQL StatefulSet (`mysql-0`) is what the backend connects to. RDS is available as a managed alternative.

### 3.4 ECR

Two repositories, both `IMMUTABLE` (tags cannot be overwritten — prevents accidental overwrites):

| Repository | Image |
|------------|-------|
| `bookstore-backend` | Node.js API |
| `bookstore-frontend` | nginx serving React build |

Retention policy: keep the 10 most recent images; older ones are automatically deleted.

### 3.5 ACM (TLS Certificate)

Certificate provisioned for:
- `b17facebook.xyz` (primary)
- `*.b17facebook.xyz` (wildcard SAN)

Used by ingress-nginx for HTTPS termination via cert-manager (Let's Encrypt `letsencrypt-prod` ClusterIssuer).

### 3.6 Route 53

**Public hosted zone** (`b17facebook.xyz`) — two A records, both aliased to the same NLB:

| Record | Type | Target |
|--------|------|--------|
| `bookstore.b17facebook.xyz` | A (ALIAS) | NLB hostname |
| `api.bookstore.b17facebook.xyz` | A (ALIAS) | NLB hostname |

**Private hosted zone** — created by the `route53` module for internal RDS endpoint resolution.

> A wildcard `*.b17facebook.xyz` only matches one subdomain level. It covers `bookstore.b17facebook.xyz` but NOT `api.bookstore.b17facebook.xyz` (two levels). Both records must be created explicitly.

### 3.7 IAM — GitHub Actions OIDC (No Static Keys)

```
GitHub Actions runner
    │ OIDC token (signed by GitHub)
    ▼
AWS STS AssumeRoleWithWebIdentity
    │
    ▼
IAM Role: bookstore-github-oidc-role
    │
    ├─ ECR: GetAuthorizationToken (*)
    └─ ECR: Push/pull on bookstore-* repos
```

The trust policy restricts assumption to commits from the `github_repo` Terraform variable (set in `terraform.tfvars`). No `AWS_ACCESS_KEY_ID` or `AWS_SECRET_ACCESS_KEY` is stored anywhere.

---

## 4. Networking Deep Dive

### 4.1 Traffic Path — HTTPS Request

```
User browser
  │ DNS: bookstore.b17facebook.xyz → NLB IP
  ▼
NLB (port 443)
  │ TCP passthrough to ingress-nginx pods
  ▼
ingress-nginx (DaemonSet/Deployment in ingress-nginx namespace)
  │ TLS termination using bookstore-tls Secret (cert-manager issued)
  │ HTTP/2 → HTTP/1.1 proxy
  │ Route by Host header:
  │   bookstore.b17facebook.xyz     → frontend-service:80
  │   api.bookstore.b17facebook.xyz → backend-service:80
  ▼
frontend-service (ClusterIP :80) → frontend pods (nginx :8080)
  OR
backend-service (ClusterIP :80) → backend pods (Node.js :3000)
  │
  ▼ (backend only)
mysql-service (ClusterIP :3306) → mysql-0 pod (MySQL :3306)
```

### 4.2 Kubernetes Network Policies

Default-deny all ingress and egress in the `bookstore` namespace. Explicit allow rules:

| Policy | Who can connect IN | Who it can connect TO |
|--------|-------------------|----------------------|
| frontend | ingress-nginx namespace only (port 8080) | backend pods (port 3000), DNS (53) |
| backend | frontend pods + ingress-nginx (port 3000) | mysql pods (port 3306), DNS (53) |
| mysql | backend pods only (port 3306) | DNS (53) |

This ensures MySQL is never reachable from the internet, and the frontend cannot directly talk to MySQL.

### 4.3 Security Groups

| SG | Inbound | Purpose |
|----|---------|---------|
| `bookstore-alb-frontend-sg` | 0.0.0.0/0 → 80, 443 | Internet-facing NLB |
| `bookstore-rds-sg` | 170.20.0.0/16 → 3306 | RDS access from VPC only |

---

## 5. Kubernetes Architecture

All application resources live in the `bookstore` namespace. Platform components (cert-manager, ESO, ingress-nginx, ArgoCD) have their own namespaces.

### 5.1 Frontend

| Resource | Spec |
|----------|------|
| Deployment | 2 replicas, image `bookstore-frontend:<sha>` |
| Container | nginx 1.27-alpine, port 8080 |
| HPA | min 2, max 5 replicas; scales on 70% CPU |
| PDB | at least 1 pod always available |
| Security | `readOnlyRootFilesystem: true`, `runAsNonRoot: true`, capabilities dropped |
| Volumes | `emptyDir` at `/tmp` (nginx writes temp files here) |

### 5.2 Backend

| Resource | Spec |
|----------|------|
| Deployment | 2 replicas, image `bookstore-backend:<sha>` |
| Container | Node.js 22-alpine, port 3000 |
| HPA | min 2, max 10 replicas; scales on 70% CPU or 80% Memory |
| PDB | at least 1 pod always available |
| Security | `readOnlyRootFilesystem: true`, `runAsNonRoot: true`, `runAsUser: 1001` |
| Config | `backend-config` ConfigMap (`DB_HOST`, `DB_PORT`, `DB_NAME`, `APP_PORT`) |
| Secrets | `db-secret` (`DB_USERNAME`, `DB_PASSWORD`) — never stored in git |

**API endpoints:**

| Method | Path | Description |
|--------|------|-------------|
| GET | `/` | Health check — returns `"hello"` |
| GET | `/books` | List all books |
| POST | `/books` | Add a book |
| PUT | `/books/:id` | Update a book |
| DELETE | `/books/:id` | Delete a book |

### 5.3 MySQL (StatefulSet)

| Resource | Spec |
|----------|------|
| StatefulSet | 1 replica (`mysql-0`) |
| Container | `mysql:8.0` |
| PVC | 10 Gi, `gp3` StorageClass (EBS volume) |
| Init scripts | `/docker-entrypoint-initdb.d/init.sql` from ConfigMap |
| Root password | from `db-secret.DB_PASSWORD` |
| Database created | `test` |
| Tables | `books (id, title, desc, price, cover)` |

The PVC (`mysql-data`) is not deleted when the pod restarts — data persists across crashes and rolling updates.

### 5.4 Ingress

Handled by **ingress-nginx** (installed via Helm). A single `Ingress` resource routes by hostname:

```yaml
bookstore.b17facebook.xyz     → frontend-service:80
api.bookstore.b17facebook.xyz → backend-service:80
```

- Forces HTTPS redirect (HTTP 301 → HTTPS)
- TLS certificate managed by **cert-manager** via `letsencrypt-prod` ClusterIssuer
- Certificate stored in `bookstore-tls` Secret in the `bookstore` namespace

### 5.5 Image Tags

Images are tagged with the first 8 characters of the git commit SHA (e.g., `02cf7c88`). `kustomization.yaml` stores the current deployed SHA and is updated by the CI pipeline on every successful deploy. ArgoCD reads this file to know which image version to run.

---

## 6. Secrets Management

No credentials are stored in git or in the CI environment (no `AWS_ACCESS_KEY_ID`). The flow uses two OIDC trust chains:

### 6.1 Database Credentials Flow

```
AWS Secrets Manager
  Secret: /bookstore/db-credentials
  Value: {"DB_USERNAME":"admin","DB_PASSWORD":"..."}
        │
        │ IRSA (IAM Roles for Service Accounts)
        ▼
External Secrets Operator (ESO)
  ClusterSecretStore: aws-secretsmanager
  ServiceAccount: external-secrets-sa
  IAM Role: bookstore-external-secrets-irsa
        │
        │ Syncs every 1 hour
        ▼
Kubernetes Secret: db-secret (namespace: bookstore)
  DB_USERNAME: admin
  DB_PASSWORD: ****
        │
        ├─ mysql-0 (MYSQL_ROOT_PASSWORD, MYSQL_USER, MYSQL_PASSWORD)
        └─ backend pods (DB_USERNAME, DB_PASSWORD env vars)
```

### 6.2 IRSA (IAM Roles for Service Accounts)

IRSA allows a Kubernetes service account to assume an AWS IAM role without any static credentials. It works via OIDC:

1. EKS creates an OIDC provider URL unique to the cluster
2. The IAM role (`bookstore-external-secrets-irsa`) trusts that OIDC provider
3. The trust policy is scoped to `system:serviceaccount:external-secrets:external-secrets-sa`
4. When the ESO pod starts, it gets a signed OIDC token → exchanges it for temporary AWS credentials → reads Secrets Manager

This is **re-configured on every `eks_bootstrap.py` run** because the OIDC provider URL changes every time the cluster is destroyed and recreated.

---

## 7. CI/CD Pipeline

Defined in `.github/workflows/ci-cd.yml`. Triggers on every push to `main`.

```
Push to main
    │
    ▼
Stage 0: Secret Scan (Gitleaks)
    │  Scans full git history for leaked keys/tokens
    │  ✗ Fails immediately if any secret found
    ▼
Stage 1: SAST & Dependency Audit
    │  npm audit --audit-level=high (backend)
    │  npm audit --audit-level=critical (frontend)
    │  Semgrep: p/nodejs + p/owasp-top-ten + p/secrets
    ▼
Stage 2: Lint & Manifest Validation
    │  ESLint — zero warnings allowed (frontend)
    │  kubeconform — validates all k8s YAML against k8s 1.31 schema
    ▼
Stage 3: Build → Trivy Scan → Push
    │  Build backend Docker image (node:22-alpine)
    │  Trivy scan — CRITICAL + HIGH CVEs = hard fail
    │  Push bookstore-backend:<sha8> to ECR
    │  Build frontend Docker image (nginx:1.27-alpine)
    │  Trivy scan — CRITICAL + HIGH CVEs = hard fail
    │  Push bookstore-frontend:<sha8> to ECR
    │  [Auth: OIDC → bookstore-github-oidc-role, no static keys]
    ▼
Stage 4: GitOps Deploy (requires manual approval)
    │  environment: production → reviewer must approve in GitHub UI
    │  kustomize edit set image bookstore-backend=...:<sha8>
    │  kustomize edit set image bookstore-frontend=...:<sha8>
    │  git commit k8s/kustomization.yaml
    │  git push (with GITHUB_TOKEN — does NOT re-trigger pipeline)
    ▼
ArgoCD detects commit → syncs cluster within 3 min
```

**Key security properties:**
- No AWS credentials stored in GitHub Secrets — only `AWS_ACCOUNT_ID` (not secret) and `AWS_ROLE_ARN`
- Images never pushed with the `latest` tag (ECR repos are IMMUTABLE — `latest` cannot be overwritten)
- All images scanned by Trivy before push — dirty images never reach ECR
- Secrets never in code, never in CI env, never in logs

---

## 8. GitOps with ArgoCD

ArgoCD runs in the cluster and is the **only thing that runs `kubectl apply`**. The CI pipeline never touches `kubectl`.

```
git push to main
    │
    ▼
CI Pipeline commits kustomization.yaml with new image SHA
    │
    ▼
ArgoCD polls GitHub repo every 3 minutes
    │ Detects kustomization.yaml changed
    ▼
ArgoCD runs: kustomize build k8s/
    │ Renders all manifests with new image tags
    ▼
ArgoCD applies diff to cluster
    │ Only changed resources are updated
    ▼
Kubernetes rolling update
    │ New pods start (new image)
    │ Readiness probe passes
    │ Old pods terminate
    ▼
Zero-downtime deployment complete
```

**ArgoCD sync policy:**
- `automated.prune: true` — if you delete a file from `k8s/`, ArgoCD deletes the resource from the cluster
- `automated.selfHeal: true` — if you `kubectl edit` something manually, ArgoCD reverts it within 3 minutes to match git

---

## 9. Complete File Structure

```
aws_three_tier_code-main/
├── main.tf                         # Root Terraform — wires all modules together
├── eks_bootstrap.py                # One-time cluster setup after terraform apply
├── gp3-storageclass.yaml           # EBS gp3 StorageClass for MySQL PVC
├── cluster-issuer.yaml             # Let's Encrypt ClusterIssuer for cert-manager
├── TROUBLESHOOTING.md              # Running log of every error hit + exact fix
├── PROJECT_ARCHITECTURE.md         # This file
│
├── modules/                        # Terraform modules (each = one AWS concern)
│   ├── network/
│   │   ├── main.tf                 # VPC, subnets, IGW, NAT gateway, route tables
│   │   ├── variables.tf            # vpc_cidr, public_subnets, private_subnets
│   │   └── output.tf               # vpc_id, public_subnet_ids, private_subnet_ids
│   ├── security/
│   │   ├── main.tf                 # Security groups: ALB (80/443 public) + RDS (3306 VPC-only)
│   │   ├── variables.tf
│   │   └── output.tf               # alb_sg_id, rds_sg_id
│   ├── eks/
│   │   ├── main.tf                 # EKS cluster, OIDC provider, node group + IAM roles
│   │   ├── variables.tf
│   │   └── output.tf               # cluster_name, cluster_endpoint, oidc_provider_arn
│   ├── ecr/
│   │   ├── main.tf                 # ECR repos (bookstore-backend, bookstore-frontend), IMMUTABLE tags
│   │   ├── variables.tf
│   │   └── output.tf               # frontend_repo_url, backend_repo_url
│   ├── rds/
│   │   ├── main.tf                 # RDS MySQL 8.0, multi-AZ, subnet group, 7-day backups
│   │   ├── variables.tf
│   │   └── output.tf               # rds_endpoint, master_user_secret_arn
│   ├── acm/
│   │   └── main.tf                 # ACM certificate for b17facebook.xyz + *.b17facebook.xyz
│   ├── route53/
│   │   ├── main.tf                 # Private hosted zone for internal RDS DNS resolution
│   │   ├── variables.tf
│   │   └── output.tf
│
├── k8s/                            # All Kubernetes manifests (managed by ArgoCD + Kustomize)
│   ├── kustomization.yaml          # Kustomize root: lists all resources + image tags (CI updates this)
│   ├── namespace.yaml              # Creates the "bookstore" namespace
│   │
│   ├── configmaps/
│   │   └── backend-config.yaml     # Non-secret config: DB_HOST, DB_PORT, DB_NAME, APP_PORT
│   │
│   ├── secrets/
│   │   ├── external-secret.yaml    # ESO ClusterSecretStore + ExternalSecret — syncs db-secret from AWS
│   │   └── db-secret.yaml          # Placeholder (actual secret created by ESO, not this file)
│   │
│   ├── database/
│   │   ├── mysql-statefulset.yaml  # MySQL StatefulSet: 1 replica, 10Gi PVC, init scripts mounted
│   │   ├── mysql-service.yaml      # ClusterIP Service :3306 → mysql pods
│   │   └── mysql-init-configmap.yaml # init.sql: CREATE DATABASE test; CREATE TABLE books; seed data
│   │
│   ├── backend/
│   │   ├── deployment.yaml         # 2 replicas, reads DB creds from db-secret, hardened securityContext
│   │   ├── service.yaml            # ClusterIP Service :80 → backend pods :3000
│   │   └── hpa.yaml                # HorizontalPodAutoscaler: scale 2–5 pods at 70% CPU
│   │
│   ├── frontend/
│   │   ├── deployment.yaml         # 2 replicas, nginx serving React build, readOnlyRootFilesystem
│   │   ├── service.yaml            # ClusterIP Service :80 → frontend pods :8080
│   │   └── hpa.yaml                # HorizontalPodAutoscaler: scale 2–5 pods at 70% CPU
│   │
│   ├── ingress/
│   │   └── ingress.yaml            # Routes bookstore.* → frontend, api.bookstore.* → backend; TLS via cert-manager
│   │
│   ├── network-policy/
│   │   └── network-policy.yaml     # Default deny-all + explicit allow: nginx→frontend→backend→mysql only
│   │
│   ├── pdb/
│   │   └── pdb.yaml                # PodDisruptionBudget: frontend + backend always keep ≥1 pod up
│   │
│   └── argocd/
│       └── application.yaml        # ArgoCD Application: watches this repo's k8s/ dir, auto-sync enabled
│
├── backend/
│   ├── index.js                    # Express API: GET/POST/PUT/DELETE /books, connects to MySQL
│   ├── package.json
│   ├── package-lock.json
│   └── Dockerfile                  # node:22-alpine, npm ci --omit=dev, non-root user, delete lock file
│
├── client/
│   ├── src/
│   │   ├── App.js                  # Root React component
│   │   └── ...                     # React components for book list, add/edit/delete
│   ├── public/
│   ├── nginx.conf                  # nginx config: serve React build, proxy /api → backend, temp paths in /tmp
│   ├── package.json
│   ├── package-lock.json
│   └── Dockerfile                  # Build stage: node:22-alpine npm build; Runner stage: nginx:1.27-alpine
│
└── .github/
    └── workflows/
        ├── ci-cd.yml               # Main pipeline: secret scan → SAST → lint → build+scan+push → deploy
        └── terraform.yml           # Terraform pipeline: fmt check → validate → plan → apply (with Trivy IaC scan)
```

---

## 10. Implementation Guide

Complete steps to deploy this project from zero.

### Prerequisites

Install these tools locally:

```
aws CLI          >= 2.x       aws --version
terraform        >= 1.10      terraform version
kubectl          >= 1.28      kubectl version
helm             >= 3.x       helm version
python           >= 3.8       python --version
git                           git --version
```

Configure AWS CLI with admin credentials:
```bash
aws configure
# Enter: Access Key ID, Secret Access Key, Region: us-west-1, Output: json
```

---

### Step 1 — Bootstrap Terraform Remote State

Before running Terraform, create the S3 bucket and DynamoDB table for remote state:

```bash
# Create S3 bucket (bucket name must be globally unique)
aws s3api create-bucket \
  --bucket bookstore-tf-state-<your-account-id> \
  --region us-west-1 \
  --create-bucket-configuration LocationConstraint=us-west-1

# Enable versioning
aws s3api put-bucket-versioning \
  --bucket bookstore-tf-state-<your-account-id> \
  --versioning-configuration Status=Enabled

# Enable encryption
aws s3api put-bucket-encryption \
  --bucket bookstore-tf-state-<your-account-id> \
  --server-side-encryption-configuration '{
    "Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

# Create DynamoDB table for state locking
aws dynamodb create-table \
  --table-name bookstore-tf-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-west-1
```

Then fill in `main.tf` backend block:

```hcl
backend "s3" {
  bucket         = "bookstore-tf-state-<your-account-id>"
  key            = "prod/terraform.tfstate"
  region         = "us-west-1"
  dynamodb_table = "bookstore-tf-lock"
  encrypt        = true
}
```

---

### Step 2 — GitHub OIDC Provider (one-time)

Allow GitHub Actions to authenticate to AWS without static keys:

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

---

### Step 3 — Terraform Apply

```bash
cd aws_three_tier_code-main
terraform init
terraform plan
terraform apply
```

This creates: VPC, subnets, NAT gateway, EKS cluster, ECR repos, RDS, ACM certificate, GitHub OIDC role, Route53 private zone.

After apply, note the outputs:
```bash
terraform output eks_cluster_name      # bookstore-eks
terraform output frontend_repo_url     # ECR URL for frontend
terraform output backend_repo_url      # ECR URL for backend
```

---

### Step 4 — GitHub Secrets

In GitHub → repo → Settings → Secrets and variables → Actions, add:

| Secret | Value |
|--------|-------|
| `AWS_ACCOUNT_ID` | Your 12-digit AWS account ID |
| `AWS_ROLE_ARN` | `arn:aws:iam::<account-id>:role/bookstore-github-oidc-role` |
| `API_URL` | `https://api.bookstore.b17facebook.xyz` |

Create a GitHub Environment named `production` (Settings → Environments) and add a required reviewer — this gates the deploy stage.

---

### Step 5 — Store DB Credentials in Secrets Manager

```bash
aws secretsmanager create-secret \
  --name /bookstore/db-credentials \
  --region us-west-1 \
  --secret-string '{"DB_USERNAME":"admin","DB_PASSWORD":"<strong-password-here>"}'
```

Choose a strong password. Note: if the password contains single quotes, they are fine — the JSON encoding handles them.

---

### Step 6 — Run eks_bootstrap.py

This script installs all cluster components in order:

```bash
python eks_bootstrap.py
```

**What it does (10 phases):**

| Phase | Action |
|-------|--------|
| 1 | Update kubeconfig (`aws eks update-kubeconfig`) |
| 2 | Install EBS CSI add-on + attach IAM policy to node role |
| 3 | Scale node group to 2 (prevents "too many pods") |
| 4 | Install cert-manager, External Secrets Operator, ingress-nginx via Helm |
| 5 | Create IRSA role + service account for ESO |
| 6 | Validate/create AWS Secrets Manager secret |
| 7 | Install ArgoCD, apply ArgoCD Application manifest |
| 8 | Clear kubectl cache, force ESO resync |
| 9 | Wait for mysql-0, create DB schema + seed data |
| 10 | Print summary + Route53 instructions |

The script is **idempotent** — safe to re-run after failures.

---

### Step 7 — Trigger CI/CD Pipeline

Push a commit to `main` to trigger the pipeline:

```bash
git add .
git commit -m "feat: initial deployment"
git push origin main
```

In GitHub Actions, watch the pipeline. When it reaches the `deploy` stage, it pauses for approval. Go to **Actions → DevSecOps Pipeline → approve** to allow the deploy stage to update `kustomization.yaml`.

After approval, the pipeline commits the new image SHA to `k8s/kustomization.yaml`. ArgoCD detects this within 3 minutes and rolls out the new pods.

---

### Step 8 — Update Route53 DNS

After `eks_bootstrap.py` completes Phase 10, it prints the NLB hostname. Go to:

**AWS Console → Route 53 → Hosted zones → b17facebook.xyz**

Create (or update) two A records:

| Record | Type | Routing | Target |
|--------|------|---------|--------|
| `bookstore.b17facebook.xyz` | A | Alias | NLB hostname from Phase 10 |
| `api.bookstore.b17facebook.xyz` | A | Alias | Same NLB hostname |

DNS propagates within 60 seconds for Route53 alias records.

---

### Step 9 — Verify

```bash
# All pods running
kubectl get pods -n bookstore

# Expected:
# frontend-xxx   1/1   Running
# frontend-xxx   1/1   Running
# backend-xxx    1/1   Running
# backend-xxx    1/1   Running
# mysql-0        1/1   Running

# TLS certificate issued
kubectl describe certificate bookstore-tls -n bookstore
# Status: True, Reason: Ready

# ArgoCD sync status
kubectl get application bookstore -n argocd
# STATUS: Synced, HEALTH: Healthy
```

Open `https://bookstore.b17facebook.xyz` — the bookstore UI loads.  
Open `https://api.bookstore.b17facebook.xyz` — returns `"hello"` (JSON).

---

### Ongoing Operations

**Deploy a new version:** Push to `main` → approve deploy stage in GitHub Actions → ArgoCD auto-deploys.

**Destroy everything:**
```bash
terraform destroy
```
Confirm with `yes`. ECR repos delete cleanly because `force_delete = true`. RDS snapshots are skipped (`skip_final_snapshot = true`).

**Re-deploy after destroy:** Repeat Steps 3–9. The OIDC provider (Step 2) and S3/DynamoDB (Step 1) survive destroy and do not need to be recreated.

**Rotate DB password:** Update the secret in Secrets Manager. ESO syncs the new value to the cluster within 1 hour (or force-sync immediately):
```bash
kubectl annotate externalsecret db-secret -n bookstore \
  "force-sync=$(date +%s)" --overwrite
```
Then restart backend pods to pick up the new env var:
```bash
kubectl rollout restart deployment/backend -n bookstore
```

---

### Pending Items

| Item | Action |
|------|--------|
| Rotate SSH keys from `3-teir` / `github` files | Those files were once public — revoke the old keys immediately |
| Fill in S3 backend block in `main.tf` | See Step 1 above |
| Re-enable `deletion_protection = true` on RDS | Once infrastructure is stable |
| Point domain registrar NS records to Route53 | Required if `b17facebook.xyz` was registered outside Route53 |
