# Bookstore — AWS Three-Tier Application

A production-grade, cloud-native bookstore application deployed on AWS using a classic three-tier architecture. The infrastructure is fully codified in Terraform, containerised with Docker, orchestrated on Kubernetes (EKS), and protected by a DevSecOps CI/CD pipeline.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Tech Stack](#tech-stack)
3. [Repository Structure](#repository-structure)
4. [Prerequisites](#prerequisites)
5. [Local Development](#local-development)
6. [Building and Pushing Docker Images](#building-and-pushing-docker-images)
7. [Infrastructure Provisioning (Terraform)](#infrastructure-provisioning-terraform)
8. [Deploying to Kubernetes (EKS)](#deploying-to-kubernetes-eks)
9. [CI/CD Pipeline](#cicd-pipeline)
10. [Secret Management](#secret-management)
11. [Security Controls](#security-controls)
12. [GitHub Secrets Reference](#github-secrets-reference)

---

## Architecture Overview

```
Internet
    │
    ▼
┌─────────────────────────────────────────────────────────────┐
│  VPC  170.20.0.0/16  (us-west-1)                            │
│                                                             │
│  Public Subnets (us-west-1a / us-west-1b)                   │
│  ┌────────────────────┐  ┌──────────────────┐               │
│  │  Internet Gateway  │  │  NAT Gateway     │               │
│  │  ALB (Frontend)    │  │                  │               │
│  └────────────────────┘  └──────────────────┘               │
│                                                             │
│  Private Subnets — App Tier                                  │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  EKS Node Group  (t3.medium × 2–4)                   │   │
│  │  ┌──────────────────┐  ┌──────────────────────────┐  │   │
│  │  │  Frontend Pods   │  │  Backend Pods            │  │   │
│  │  │  (React / Nginx) │  │  (Node.js / Express)     │  │   │
│  │  └──────────────────┘  └──────────────────────────┘  │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                             │
│  Private Subnets — Data Tier                                 │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  RDS MySQL 8.0  (db.t3.micro, Multi-AZ)              │   │
│  │  — OR —                                              │   │
│  │  MySQL StatefulSet in-cluster (dev / local k8s)      │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

**Traffic flow:**
1. User hits the public ALB → Nginx Ingress → Frontend React SPA
2. Frontend calls `api.bookstore.b17facebook.xyz` → Backend Node.js API
3. Backend reads/writes to MySQL (RDS in prod, StatefulSet in-cluster for dev)

---

## Tech Stack

| Layer | Technology |
|---|---|
| Frontend | React 18, Nginx 1.25 (Alpine) |
| Backend | Node.js 18, Express, mysql2 |
| Database | MySQL 8.0 |
| Container Registry | Amazon ECR |
| Orchestration | Kubernetes 1.31 on Amazon EKS |
| Infrastructure as Code | Terraform ≥ 1.7, AWS provider ~5.0 |
| CI/CD | GitHub Actions |
| Secret Management | AWS Secrets Manager + External Secrets Operator |
| Security Scanning | Trivy (containers), Gitleaks (secrets), Semgrep (SAST), tfsec (IaC) |
| TLS | cert-manager + Let's Encrypt (k8s path) / AWS ACM (EC2 path) |

---

## Repository Structure

```
.
├── backend/                  # Node.js/Express API
│   ├── Dockerfile
│   ├── index.js              # Express routes (CRUD /books)
│   ├── package.json
│   └── test.sql              # Schema seed for local MySQL
│
├── client/                   # React frontend
│   ├── Dockerfile            # Multi-stage: build → Nginx
│   ├── nginx.conf
│   └── src/
│       └── pages/config.js   # Set REACT_APP_API_URL here for local dev
│
├── k8s/                      # Kubernetes manifests
│   ├── namespace.yaml
│   ├── configmaps/
│   │   └── backend-config.yaml
│   ├── secrets/
│   │   ├── db-secret.yaml          # LOCAL DEV ONLY — never commit real values
│   │   └── external-secret.yaml    # PRODUCTION — ESO syncs from Secrets Manager
│   ├── database/
│   │   ├── mysql-statefulset.yaml  # In-cluster MySQL (dev / local k8s)
│   │   ├── mysql-service.yaml      # Headless service for StatefulSet DNS
│   │   └── mysql-init-configmap.yaml
│   ├── backend/
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   └── hpa.yaml
│   ├── frontend/
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   └── hpa.yaml
│   ├── ingress/
│   │   └── ingress.yaml
│   ├── network-policy/
│   │   └── network-policy.yaml
│   └── pdb/
│       └── pdb.yaml
│
├── modules/                  # Terraform reusable modules
│   ├── acm/                  # ACM TLS certificate
│   ├── asg/                  # Auto Scaling Groups
│   ├── bastion/              # Bastion host
│   ├── ecr/                  # ECR repositories
│   ├── eks/                  # EKS cluster + OIDC + node group
│   ├── launch_templates/     # EC2 launch templates
│   ├── load_balancers/       # ALBs + target groups
│   ├── network/              # VPC, subnets, NAT gateway
│   ├── rds/                  # RDS MySQL (production)
│   ├── route53/              # DNS records
│   └── security/             # Security groups
│
├── scripts/
│   └── build-and-push.sh     # Manual Docker build + ECR push helper
│
├── .github/workflows/
│   ├── ci-cd.yml             # DevSecOps application pipeline
│   └── terraform.yml         # Terraform plan / apply pipeline
│
└── main.tf                   # Root Terraform configuration
```

---

## Prerequisites

| Tool | Minimum Version | Purpose |
|---|---|---|
| Node.js | 18 | Local backend/frontend development |
| Docker | 24 | Building images |
| Terraform | 1.7 | Provisioning AWS infrastructure |
| AWS CLI | 2.x | ECR login, EKS kubeconfig |
| kubectl | 1.31 | Deploying k8s manifests |
| helm | 3.x | Installing cluster add-ons (ESO, cert-manager) |

---

## Local Development

### Backend

```bash
cd backend
npm install

# Create .env with your local MySQL details
cat > .env <<EOF
DB_HOST=localhost
DB_USERNAME=root
DB_PASSWORD=yourpassword
DB_PORT=3306
DB_NAME=test
APP_PORT=3000
EOF

# Seed the database
mysql -u root -p < test.sql

# Start the server
node index.js
```

The API is available at `http://localhost:3000`.

### Frontend

```bash
cd client
npm install

# Point the frontend at your local backend
# Edit src/pages/config.js:
#   const API_BASE_URL = "http://localhost:3000";

npm start          # development server on :3000
# or
npm run build      # production build → build/
```

---

## Building and Pushing Docker Images

The helper script wraps the ECR login, Docker build, and push steps into one command.

```bash
# Usage
./scripts/build-and-push.sh <AWS_ACCOUNT_ID> <AWS_REGION> <IMAGE_TAG> [REACT_APP_API_URL]

# Example
./scripts/build-and-push.sh 123456789012 us-west-1 v1.2.0 https://api.bookstore.b17facebook.xyz
```

The script will:
1. Authenticate to ECR using `aws ecr get-login-password` (requires AWS CLI credentials)
2. Build the frontend image with the API URL injected at build time
3. Build the backend image
4. Push both images and tag them as `latest`

> The CI/CD pipeline performs these steps automatically on every merge to `main`. Manual use of this script is for hotfixes or pre-release testing only.

---

## Infrastructure Provisioning (Terraform)

### First-time setup

> Optionally enable remote state before running `init`. Uncomment the `backend "s3"` block in `main.tf` and create the S3 bucket and DynamoDB table first.

```bash
# 1. Initialise providers and modules
terraform init

# 2. Preview changes (safe — read-only)
terraform plan -var="allowed_ssh_cidr=<YOUR_IP>/32"

# 3. Apply
terraform apply -var="allowed_ssh_cidr=<YOUR_IP>/32"
```

### What Terraform provisions

| Module | Resources created |
|---|---|
| `network` | VPC, 2 public + 6 private subnets, IGW, NAT Gateway, route tables |
| `security` | Security groups for ALB, EC2 (frontend/backend), RDS, bastion |
| `acm` | ACM TLS certificate for `b17facebook.xyz` and `*.b17facebook.xyz` |
| `rds` | MySQL 8.0, Multi-AZ, automated backups, deletion protection |
| `ecr` | Two ECR repositories — `bookstore-frontend` and `bookstore-backend` |
| `eks` | EKS 1.31 cluster, OIDC provider, managed node group (t3.medium × 2–4) |
| `alb` | Frontend public ALB + backend internal ALB, target groups, HTTPS listeners |
| `launch_templates` | EC2 launch templates for the classic EC2 ASG path |
| `asg` | Auto Scaling Groups for EC2-based frontend/backend (legacy path) |
| `bastion` | Bastion host in public subnet for emergency SSH access |
| `route53` | DNS records wiring the domain to the ALBs |

### Key outputs after apply

```bash
terraform output eks_cluster_name       # bookstore-eks
terraform output eks_cluster_endpoint   # https://...
terraform output rds_endpoint           # bookstore-db.xxx.rds.amazonaws.com
terraform output frontend_repo_url      # <account>.dkr.ecr.us-west-1.amazonaws.com/bookstore-frontend
terraform output backend_repo_url       # <account>.dkr.ecr.us-west-1.amazonaws.com/bookstore-backend
terraform output bastion_ip             # x.x.x.x
```

---

## Deploying to Kubernetes (EKS)

### 1. Install cluster add-ons (one-time)

```bash
# Configure kubectl
aws eks update-kubeconfig --name bookstore-eks --region us-west-1

# EBS CSI driver (required for gp3 PVCs used by MySQL StatefulSet)
aws eks create-addon --cluster-name bookstore-eks --addon-name aws-ebs-csi-driver

# cert-manager (manages Let's Encrypt TLS certificates)
helm repo add jetstack https://charts.jetstack.io
helm install cert-manager jetstack/cert-manager \
  -n cert-manager --create-namespace \
  --set installCRDs=true

# External Secrets Operator (syncs secrets from AWS Secrets Manager)
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace

# Nginx Ingress Controller
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace
```

### 2. Store DB credentials in AWS Secrets Manager

```bash
aws secretsmanager create-secret \
  --name /bookstore/db-credentials \
  --region us-west-1 \
  --secret-string '{"DB_USERNAME":"admin","DB_PASSWORD":"<strong-password>"}'
```

### 3. Apply manifests

```bash
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/configmaps/
kubectl apply -f k8s/secrets/external-secret.yaml   # pulls from Secrets Manager
kubectl apply -f k8s/database/                      # in-cluster MySQL (dev only)
kubectl apply -f k8s/network-policy/
kubectl apply -f k8s/pdb/
kubectl apply -f k8s/backend/
kubectl apply -f k8s/frontend/
kubectl apply -f k8s/ingress/
```

### 4. Replace image placeholders

The deployment manifests reference `ACCOUNT_ID` as a placeholder:
```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=us-west-1

find k8s/backend k8s/frontend -name "*.yaml" \
  -exec sed -i "s/ACCOUNT_ID/${ACCOUNT_ID}/g" {} +
```

---

## CI/CD Pipeline

The pipeline is defined in [.github/workflows/ci-cd.yml](.github/workflows/ci-cd.yml) and runs on every push or pull request to `main`.

### Stages

```
Push/PR to main
     │
     ▼
┌────────────────────┐
│ 0. Secret Scan     │ Gitleaks — fails immediately on any detected secret
└─────────┬──────────┘
          │
     ┌────┴────┐
     ▼         ▼
┌─────────┐  ┌────────────┐
│ 1. SAST │  │ 2. Validate│
│ npm audit│  │ ESLint     │
│ Semgrep  │  │ kubeval    │
└────┬────┘  └─────┬──────┘
     └──────┬──────┘
            │  (both must pass)
            ▼
┌───────────────────────────┐
│ 3. Build → Scan → Push    │ main branch only
│ Docker build (backend)    │
│ Trivy scan → SARIF upload │
│ Push to ECR               │
│ Docker build (frontend)   │
│ Trivy scan → SARIF upload │
│ Push to ECR               │
└────────────┬──────────────┘
             │  (manual approval gate)
             ▼
┌───────────────────────────┐
│ 4. Deploy to EKS          │ main branch only, production environment
│ Apply k8s manifests       │
│ Sync secrets via ESO      │
│ kubectl set image         │
│ rollout status check      │
└───────────────────────────┘
```

### Authentication model

The pipeline uses **GitHub OIDC** to assume an AWS IAM role. No `AWS_ACCESS_KEY_ID` or `AWS_SECRET_ACCESS_KEY` are stored anywhere. The IAM role trust policy must allow `token.actions.githubusercontent.com` as a federated identity.

---

## Secret Management

| Context | Mechanism | How it works |
|---|---|---|
| Production (EKS) | External Secrets Operator | ESO controller reads from AWS Secrets Manager and creates a native k8s Secret in-cluster |
| CI/CD pipeline | GitHub Secrets only | `AWS_ROLE_ARN`, `AWS_ACCOUNT_ID`, `API_URL` — no DB credentials in the pipeline at all |
| Local development | `.env` file | Never committed; see `.gitignore` |
| Terraform state | AWS Secrets Manager + SSM | RDS credentials stored at `/bookstore/rds/secret-arn` |

**Rule:** No credential, password, or account ID should ever appear in plain text in any committed file.

---

## Security Controls

| Control | Implementation |
|---|---|
| Secret detection | Gitleaks scans every commit and full git history |
| SAST | Semgrep with Node.js + OWASP Top-10 rule packs |
| Dependency CVEs | `npm audit --audit-level=high` on backend and frontend |
| Container CVEs | Trivy blocks pushes on CRITICAL/HIGH unfixed vulns |
| IaC security | tfsec runs on every Terraform change |
| No static AWS keys | GitHub OIDC → IAM role assumption |
| Secrets in-cluster | External Secrets Operator + AWS Secrets Manager |
| Non-root containers | All pods run as non-root (UID 1001/101) |
| Read-only filesystems | `readOnlyRootFilesystem: true` on all app containers |
| Network segmentation | Kubernetes NetworkPolicy restricts pod-to-pod traffic |
| TLS everywhere | cert-manager + Let's Encrypt; force-redirect HTTP → HTTPS |
| Manual deploy gate | GitHub Environments `production` requires reviewer approval |

---

## GitHub Secrets Reference

Configure these in **Settings → Secrets and variables → Actions** before running the pipeline:

| Secret | Description | Example |
|---|---|---|
| `AWS_ACCOUNT_ID` | Your 12-digit AWS account ID | `123456789012` |
| `AWS_ROLE_ARN` | ARN of the OIDC IAM role the pipeline assumes | `arn:aws:iam::123456789012:role/bookstore-github-oidc-role` |
| `API_URL` | Public URL of the backend API (injected into the React build) | `https://api.bookstore.b17facebook.xyz` |
| `SEMGREP_APP_TOKEN` | Semgrep Cloud token (optional — remove the env line if not using Semgrep Cloud) | `token...` |
