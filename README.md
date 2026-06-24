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
Route 53  (b17facebook.xyz)
    │  bookstore.b17facebook.xyz     → NLB
    │  api.bookstore.b17facebook.xyz → NLB
    ▼
AWS Network Load Balancer  (port 80/443)
    │
    ▼
┌─────────────────────────────────────────────────────────────┐
│  VPC  170.20.0.0/16  (us-west-1)                            │
│                                                             │
│  Public Subnets (us-west-1a / us-west-1c)                   │
│  ┌────────────────────┐  ┌──────────────────┐               │
│  │  Internet Gateway  │  │  NAT Gateway     │               │
│  │  NLB ENIs          │  │  (outbound only) │               │
│  └────────────────────┘  └──────────────────┘               │
│                                                             │
│  Private Subnets — App Tier                                  │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  EKS Node Group  (t3.medium × 1–2, desired 1)        │   │
│  │  ┌──────────────────┐  ┌──────────────────────────┐  │   │
│  │  │  Frontend Pods   │  │  Backend Pods            │  │   │
│  │  │  (React / Nginx) │  │  (Node.js / Express)     │  │   │
│  │  │  Deployment      │  │  Argo Rollout (canary)   │  │   │
│  │  └──────────────────┘  └──────────────────────────┘  │   │
│  │  MySQL StatefulSet (dev — in-cluster)                │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                             │
│  Private Subnets — Data Tier                                 │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  RDS MySQL 8.0  (db.t3.micro, Multi-AZ)              │   │
│  │  Production database (managed alternative to         │   │
│  │  in-cluster StatefulSet)                             │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

**Traffic flow:**
1. User → Route 53 → NLB → ingress-nginx (TLS termination) → Frontend React SPA
2. Frontend calls `api.bookstore.b17facebook.xyz` → same NLB → Backend Node.js API (Argo Rollout)
3. Backend reads/writes to MySQL StatefulSet (dev) or RDS (prod)
4. Prometheus scrapes backend `/metrics` → Grafana dashboards in `monitoring` namespace

---

## Tech Stack

| Layer | Technology |
|---|---|
| Frontend | React 18, Nginx 1.27 (Alpine) |
| Backend | Node.js 22, Express, mysql2, prom-client |
| Database | MySQL 8.0 |
| Container Registry | Amazon ECR |
| Orchestration | Kubernetes 1.31 on Amazon EKS |
| Progressive Delivery | Argo Rollouts (canary — backend) |
| Infrastructure as Code | Terraform ≥ 1.7, AWS provider ~5.0, Helm provider |
| CI/CD | GitHub Actions |
| GitOps | ArgoCD (watches `k8s/overlays/prod/`) |
| Secret Management | AWS Secrets Manager + External Secrets Operator |
| Observability | Prometheus + Grafana (kube-prometheus-stack) |
| Security Scanning | Trivy (containers), Gitleaks (secrets), Semgrep (SAST), tfsec (IaC) |
| TLS | cert-manager + Let's Encrypt |
| Testing | Vitest (6 unit tests, vi.fn() mock db) |

---

## Repository Structure

```
.
├── main.tf                   # Root Terraform configuration (+ Helm provider + eks_addons module)
├── eks_bootstrap.py          # 8-phase cluster setup script (post terraform apply)
├── cluster-issuer.yaml       # Let's Encrypt ClusterIssuer (applied by bootstrap Phase 2)
│
├── backend/                  # Node.js/Express API
│   ├── Dockerfile
│   ├── app.js                # createApp(db) factory — all routes + /metrics (prom-client)
│   ├── index.js              # Creates MySQL connection, starts server
│   ├── package.json          # "test": "vitest run"
│   └── __tests__/
│       └── books.test.js     # 6 vitest tests, vi.fn() mock db
│
├── client/                   # React frontend
│   ├── Dockerfile            # Multi-stage: build → Nginx
│   ├── nginx.conf
│   └── src/
│       └── pages/config.js   # Set REACT_APP_API_URL here for local dev
│
├── k8s/                      # Kubernetes manifests (Kustomize base + overlays)
│   ├── base/                 # Shared resources — no image tags, no HPAs
│   │   ├── kustomization.yaml
│   │   ├── namespace.yaml
│   │   ├── storageclass/
│   │   │   └── gp3.yaml             # EBS gp3 StorageClass (declarative, managed by ArgoCD)
│   │   ├── configmaps/
│   │   │   └── backend-config.yaml
│   │   ├── secrets/
│   │   │   └── external-secret.yaml # PRODUCTION — ESO syncs from Secrets Manager
│   │   ├── database/
│   │   │   ├── mysql-statefulset.yaml
│   │   │   ├── mysql-service.yaml
│   │   │   └── mysql-init-configmap.yaml
│   │   ├── backend/
│   │   │   ├── rollout.yaml         # Argo Rollout (canary — replaces deployment.yaml)
│   │   │   └── service.yaml         # port named "http" for ServiceMonitor
│   │   ├── frontend/
│   │   │   ├── deployment.yaml
│   │   │   └── service.yaml
│   │   ├── ingress/
│   │   │   └── ingress.yaml
│   │   ├── monitoring/
│   │   │   └── servicemonitor.yaml  # Prometheus scrapes backend /metrics
│   │   ├── network-policy/
│   │   │   └── network-policy.yaml
│   │   └── pdb/
│   │       └── pdb.yaml
│   ├── overlays/
│   │   ├── dev/
│   │   │   └── kustomization.yaml   # Patches replicas=1 on Rollout + Deployment
│   │   └── prod/
│   │       ├── kustomization.yaml   # Image tags (CI updates) + backend resource limits
│   │       ├── hpa-backend.yaml     # HPA: Rollout/backend min 1 max 5
│   │       └── hpa-frontend.yaml    # HPA: Deployment/frontend min 1 max 3
│   ├── argocd/
│   │   └── application.yaml         # ArgoCD Application: path = k8s/overlays/prod
│   └── secrets/
│       └── db-secret.yaml           # LOCAL DEV ONLY — never commit real values
│
├── modules/                  # Terraform reusable modules
│   ├── acm/                  # ACM TLS certificate
│   ├── ecr/                  # ECR repositories
│   ├── eks/                  # EKS cluster + OIDC + node group
│   ├── eks-addons/           # Helm releases: cert-manager, ESO, ingress-nginx,
│   │                         #   ArgoCD, kube-prometheus-stack, argo-rollouts
│   ├── network/              # VPC, subnets, NAT gateway
│   ├── rds/                  # RDS MySQL (production)
│   ├── route53/              # Private hosted zone for RDS DNS
│   └── security/             # Security groups
│
├── scripts/
│   ├── build-and-push.sh     # Manual Docker build + ECR push helper
│   ├── bootstrap-tf-state.sh # Creates S3 + DynamoDB for Terraform remote state
│   └── configure.py          # Stamps config.env values into k8s files and terraform.tfvars
│
├── .github/workflows/
│   ├── ci-cd.yml             # DevSecOps application pipeline (triggers on main + improvements)
│   └── terraform.yml         # Terraform plan / apply pipeline
│
└── TROUBLESHOOTING.md        # Running log of errors and fixes
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
| helm | 3.x | Querying cluster add-ons (installed by Terraform) |
| kustomize | 5.x | Building manifests locally |

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

# Seed the database — copy the SQL from k8s/base/database/mysql-init-configmap.yaml
mysql -u root -p -e "CREATE DATABASE IF NOT EXISTS test; USE test; ..."

# Start the server
node index.js
# Connected to backend on port 3000.
```

The API is available at `http://localhost:3000`. The `/metrics` endpoint is available at `http://localhost:3000/metrics`.

### Run tests (no database required)

```bash
cd backend
npm test
# Runs 6 vitest tests using a vi.fn() mock db — no MySQL needed.
```

### Frontend

```bash
cd client
npm install

# Point the frontend at your local backend
# Edit src/pages/config.js:
#   const API_BASE_URL = "http://localhost:3000";

npm start          # development server on :3001
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

> The CI/CD pipeline performs these steps automatically on every merge to `main`. Manual use of this script is for hotfixes or pre-release testing only.

---

## Infrastructure Provisioning (Terraform)

### First-time setup

> Run `./scripts/bootstrap-tf-state.sh us-west-1` first to create the S3 bucket and DynamoDB table for remote state, then fill in the `backend "s3"` block in `main.tf`.

```bash
# 1. Configure values (domain, account ID, GitHub repo)
cp config.env.example config.env
# Edit config.env, then:
python scripts/configure.py

# 2. Initialise providers and modules
terraform init

# 3. Preview changes (safe — read-only)
terraform plan

# 4. Apply
terraform apply
```

### What Terraform provisions

| Module | Resources created |
|---|---|
| `network` | VPC `170.20.0.0/16`, 2 public + 6 private subnets (us-west-1a/1c), IGW, NAT Gateway, route tables |
| `security` | 2 security groups: NLB (80/443 public) and RDS (3306 from VPC CIDR only) |
| `acm` | ACM TLS certificate for `b17facebook.xyz` and `*.b17facebook.xyz` |
| `rds` | MySQL 8.0, `db.t3.micro`, Multi-AZ, 7-day backups, password in Secrets Manager |
| `ecr` | `bookstore-frontend` and `bookstore-backend` repos, IMMUTABLE tags, 10-image retention |
| `eks` | EKS 1.31 cluster, OIDC provider, managed node group (t3.medium, min 1 / desired 1 / max 2) |
| `eks-addons` | EBS CSI driver, cert-manager, ESO, ingress-nginx, ArgoCD, Prometheus+Grafana, Argo Rollouts |
| `route53` | Private hosted zone for internal RDS DNS resolution |

### Key outputs after apply

```bash
terraform output eks_cluster_name       # bookstore-eks
terraform output eks_cluster_endpoint   # https://...
terraform output rds_endpoint           # bookstore-db.xxx.rds.amazonaws.com
terraform output frontend_repo_url      # <account>.dkr.ecr.us-west-1.amazonaws.com/bookstore-frontend
terraform output backend_repo_url       # <account>.dkr.ecr.us-west-1.amazonaws.com/bookstore-backend
```

---

## Deploying to Kubernetes (EKS)

### 1. Run eks_bootstrap.py (post-terraform, one-time per cluster)

After `terraform apply`, all Helm add-ons are already running. The bootstrap script handles the remaining cluster-specific steps:

```bash
source config.env
DOMAIN=$DOMAIN python eks_bootstrap.py
```

**8 phases:**

| Phase | What it does |
|---|---|
| 1 | Sync kubeconfig |
| 2 | Apply ClusterIssuer (Let's Encrypt) |
| 3 | Create IRSA role for External Secrets |
| 4 | Validate / create Secrets Manager secret |
| 5 | Apply ArgoCD Application manifest |
| 6 | Clear kubectl cache + force ESO resync |
| 7 | DB schema init + seed data |
| 8 | Summary + Route53 NLB hostname |

### 2. Store DB credentials in AWS Secrets Manager

`eks_bootstrap.py` Phase 4 handles this interactively. Or do it manually:

```bash
aws secretsmanager create-secret \
  --name /bookstore/db-credentials \
  --region us-west-1 \
  --secret-string '{"DB_USERNAME":"admin","DB_PASSWORD":"<strong-password>"}'
```

### 3. Apply the ArgoCD Application manifest

`eks_bootstrap.py` Phase 5 does this automatically. To apply manually:

```bash
kubectl apply -f k8s/argocd/application.yaml
```

ArgoCD watches `k8s/overlays/prod/` and reconciles the cluster automatically within 3 minutes of every git commit.

### 4. Update image references

The CI pipeline updates `k8s/overlays/prod/kustomization.yaml` automatically via `kustomize edit set image` after every successful build. To update manually:

```bash
cd k8s/overlays/prod
kustomize edit set image \
  bookstore-backend=<ACCOUNT>.dkr.ecr.us-west-1.amazonaws.com/bookstore-backend:<sha8>
kustomize edit set image \
  bookstore-frontend=<ACCOUNT>.dkr.ecr.us-west-1.amazonaws.com/bookstore-frontend:<sha8>
git add kustomization.yaml && git commit -m "chore: update image tags" && git push
```

---

## CI/CD Pipeline

The pipeline is defined in [.github/workflows/ci-cd.yml](.github/workflows/ci-cd.yml) and triggers on every push or pull request to `main` or `improvements`.

### Stages

```
Push/PR to main or improvements
     │
     ▼
┌────────────────────┐
│ 0. Secret Scan     │ Gitleaks — fails immediately on any detected secret
└─────────┬──────────┘
          │
     ┌────┴────┐
     ▼         ▼
┌─────────────────┐  ┌────────────┐
│ 1. SAST + Tests │  │ 2. Validate│
│ npm test (vitest)│  │ ESLint     │
│ npm audit       │  │ kubeconform│
│ Semgrep         │  │            │
└────┬────────────┘  └─────┬──────┘
     └──────┬──────────────┘
            │  (both must pass)
            ▼
┌───────────────────────────┐
│ 3. Build → Scan → Push    │ main or improvements only
│ Docker build (backend)    │
│ Trivy scan → SARIF upload │
│ Push to ECR  :<sha8>      │
│ Docker build (frontend)   │
│ Trivy scan → SARIF upload │
│ Push to ECR  :<sha8>      │
└────────────┬──────────────┘
             │  (manual approval gate)
             ▼
┌───────────────────────────────────────┐
│ 4. GitOps image-tag update            │ production environment
│ cd k8s/overlays/prod                  │
│ kustomize edit set image → <sha8>     │
│ git commit k8s/overlays/prod/         │
│   kustomization.yaml                  │
│ git push (GITHUB_TOKEN)               │
│                                       │
│ ArgoCD detects commit (~3 min)        │
│ kustomize build k8s/overlays/prod/    │
│ Backend: Argo Rollout canary          │
│ Frontend: rolling update              │
└───────────────────────────────────────┘
```

### Authentication model

The pipeline uses **GitHub OIDC** to assume an AWS IAM role. No `AWS_ACCESS_KEY_ID` or `AWS_SECRET_ACCESS_KEY` are stored anywhere.

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
| Unit tests | Vitest (6 tests) — runs before audit in CI Stage 1 |
| Dependency CVEs | `npm audit --omit=dev --audit-level=high` on backend and frontend |
| Container CVEs | Trivy blocks pushes on CRITICAL/HIGH unfixed vulns |
| IaC security | tfsec runs on every Terraform change |
| No static AWS keys | GitHub OIDC → IAM role assumption |
| Secrets in-cluster | External Secrets Operator + AWS Secrets Manager |
| Non-root containers | All pods run as non-root (UID 1001/101) |
| Read-only filesystems | `readOnlyRootFilesystem: true` on all app containers |
| Network segmentation | Kubernetes NetworkPolicy restricts pod-to-pod traffic |
| TLS everywhere | cert-manager + Let's Encrypt; force-redirect HTTP → HTTPS |
| Progressive delivery | Argo Rollouts canary on backend — easy rollback if errors spike |
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
