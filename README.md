# Bookstore — AWS Three-Tier Application

A production-grade, cloud-native bookstore application deployed on AWS using a classic three-tier architecture. The infrastructure is fully codified in Terraform, containerised with Docker, orchestrated on Kubernetes (EKS), and protected by a DevSecOps CI/CD pipeline.

> **Note:** this README describes the original monolith. As of the `observability` branch, all 5 planned microservices (`catalog-service`, `user-service`, `order-service`, `notification-service`, `api-gateway`) are built, registered with ArgoCD, and reachable — the frontend (`client/`) has a real login/register/cart/checkout/order-history UI wired to them via `api-gateway`, and the Ingress-host collision that used to block the gateway from being reliably reachable is resolved. `backend/`/`k8s/base/` (the old monolith) still exist and still serve the frontend's static assets — the final backend-deletion step is intentionally paused, see [`docs/FUTURE_IMPROVEMENTS.md`](docs/FUTURE_IMPROVEMENTS.md). Monitoring has also moved off-cluster onto a dedicated EC2 instance. The docs below reflect the actual current state — start there if anything here seems out of date.

## Documentation

| Doc | Covers |
|---|---|
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | System-level view: current state, module graph, region layout, the microservices platform |
| [`docs/ARCHITECTURE_DIAGRAM_PROMPT.md`](docs/ARCHITECTURE_DIAGRAM_PROMPT.md) | Ready-to-use prompt for generating an official-AWS-style architecture/networking diagram |
| [`docs/CICD_DIAGRAM_PROMPT.md`](docs/CICD_DIAGRAM_PROMPT.md) | Ready-to-use prompt for generating an official-AWS-style CI/CD pipeline diagram |
| [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) | How to actually stand this up from zero, step by step |
| [`docs/TERRAFORM.md`](docs/TERRAFORM.md) | Every Terraform module in depth |
| [`docs/KUBERNETES.md`](docs/KUBERNETES.md) | Manifests, Kustomize layout, ArgoCD wiring |
| [`docs/CICD.md`](docs/CICD.md) | The GitHub Actions pipeline, job by job |
| [`docs/OBSERVABILITY.md`](docs/OBSERVABILITY.md) | Every monitoring/logging/alerting tool, how it's wired, how to use it |
| [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) | Real errors hit, root causes, fixes |
| [`docs/FUTURE_IMPROVEMENTS.md`](docs/FUTURE_IMPROVEMENTS.md) | What's next, known gaps, longer-term roadmap |

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
│   ├── init-backend.sh       # Creates S3 bucket for Terraform remote state (native lockfile locking)
│   ├── init-domain.sh        # Creates Route53 public zone once per domain, ever (never destroyed)
│   ├── bootstrap-tf-state.sh # DEPRECATED — old S3+DynamoDB bootstrap, kept for reference only
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

## Infrastructure Provisioning, Kubernetes Deploy, and CI/CD Pipeline

This project has grown from a single frontend/backend pair into 5 backend
microservices behind an api-gateway, provisioned by 9 Terraform modules,
deployed via ArgoCD GitOps. The step-by-step guides live in `docs/` and are
kept current there instead of duplicated here:

- [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) — full stand-up from a fresh AWS
  account: Terraform state bootstrap, `config.env`/`scripts/configure.py`,
  the apply itself, and post-apply verification.
- [`docs/TERRAFORM.md`](docs/TERRAFORM.md) — what each of the 9 modules
  provisions.
- [`docs/CICD.md`](docs/CICD.md) — the GitHub Actions pipeline stage by
  stage, plus [`explaination/CICD_EXPLAINED.md`](explaination/CICD_EXPLAINED.md)
  (local, gitignored) for a deeper walkthrough.
- [`docs/KUBERNETES.md`](docs/KUBERNETES.md) — the GitOps layout ArgoCD
  reconciles.


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
