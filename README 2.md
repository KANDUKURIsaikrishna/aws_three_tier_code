# Bookstore — AWS Three-Tier Architecture (EKS Edition)

![3-Tier Architecture](3_tier_architecture.png)

A production-grade three-tier bookstore application running on **Amazon EKS** with full GitOps delivery, DevSecOps CI/CD, and zero static AWS credentials.

---

## Architecture Overview

```
Internet
    │
    ▼
Route 53 (b17facebook.xyz)
    │  bookstore.b17facebook.xyz     → NLB
    │  api.bookstore.b17facebook.xyz → NLB
    ▼
AWS Network Load Balancer (NLB)
    │  Port 80 / 443 — ingress-nginx handles TLS termination
    ▼
┌─────────────────────────────────────────────────────────────┐
│  VPC  170.20.0.0/16  —  us-west-1                           │
│                                                             │
│  Public Subnets (NAT Gateway / NLB ENIs)                    │
│  ┌──────────────────────┐  ┌──────────────────────┐         │
│  │ 170.20.1.0/24        │  │ 170.20.2.0/24         │        │
│  │ us-west-1a           │  │ us-west-1c            │        │
│  │ Internet Gateway     │  │ NAT Gateway           │        │
│  └──────────────────────┘  └──────────────────────┘         │
│                                                             │
│  Private Subnets — App Tier (EKS nodes)                     │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  EKS Managed Node Group  (t3.medium, desired 2)       │  │
│  │                                                       │  │
│  │  Namespace: bookstore                                 │  │
│  │  ┌──────────────────┐  ┌───────────────────┐          │  │
│  │  │  Frontend Pods   │  │  Backend Pods     │          │  │
│  │  │  React + nginx   │  │  Node.js/Express  │          │  │
│  │  │  replicas: 2     │  │  replicas: 2      │          │  │
│  │  │  port: 8080      │  │  port: 3000       │          │  │
│  │  └──────────────────┘  └─────────┬─────────┘          │  │
│  │                                  │ :3306              │  │
│  │                       ┌──────────▼──────────┐         │  │
│  │                       │  mysql-0             │         │  │
│  │                       │  StatefulSet (dev)   │         │  │
│  │                       │  10 Gi EBS volume    │         │  │
│  │                       └─────────────────────┘         │  │
│  └───────────────────────────────────────────────────────┘  │
│                                                             │
│  Private Subnets — Data Tier (RDS)                          │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  RDS MySQL 8.0  (db.t3.micro, Multi-AZ)               │  │
│  │  170.20.7.0/24 (us-west-1a) + 170.20.8.0/24 (1c)     │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘

AWS Services (outside VPC)
  ECR            — Docker image registry
  Secrets Manager — /bookstore/db-credentials
  IAM / OIDC     — Keyless auth for GitHub Actions + ESO
  ACM            — TLS cert for *.b17facebook.xyz
```

---

## Tier Breakdown

### 1. Presentation Tier — React + nginx
- **React 18** SPA served by **nginx 1.27-alpine**
- Docker image built by CI, pushed to ECR, tagged with git SHA
- Kubernetes Deployment: 2 replicas, HPA scales 2–5 pods on 70% CPU
- Non-root (UID 101), read-only filesystem, capabilities dropped

### 2. Application Tier — Node.js/Express API
- **Node.js 22** REST API — CRUD endpoints for `/books`
- Connects to MySQL via env vars from Kubernetes Secret (`db-secret`)
- Kubernetes Deployment: 2 replicas, HPA scales 2–10 pods on 70% CPU / 80% Memory
- Non-root (UID 1001), read-only filesystem, capabilities dropped

### 3. Data Tier — MySQL
- **In-cluster:** MySQL 8.0 StatefulSet (`mysql-0`) on 10 Gi EBS (`gp3`) PVC — used in dev/EKS
- **Managed:** RDS MySQL 8.0 Multi-AZ — available as production alternative
- Schema auto-initialized via ConfigMap init scripts on first boot
- Root password pulled from `db-secret` Kubernetes Secret (never hardcoded)

---

## Networking

| Layer | Component | How |
|-------|-----------|-----|
| DNS | Route 53 A records (Alias) | Both hostnames → same NLB |
| Ingress | ingress-nginx + NLB | TLS termination, host-based routing |
| TLS | cert-manager + Let's Encrypt | Auto-issued, auto-renewed |
| Pod-to-pod | Kubernetes NetworkPolicy | Default deny-all; explicit allow per tier |
| Egress | NAT Gateway | EKS nodes reach ECR + AWS APIs |
| RDS access | Security Group (3306 from VPC CIDR only) | No internet exposure |

---

## CI/CD and GitOps

```
Developer pushes to main
    │
    ▼
GitHub Actions — DevSecOps Pipeline
    │  Stage 0: Gitleaks secret scan
    │  Stage 1: Semgrep SAST + npm audit
    │  Stage 2: ESLint + kubeconform
    │  Stage 3: Docker build → Trivy scan → ECR push (:<sha8>)
    │  Stage 4: kustomize update → git commit  [requires approval]
    ▼
ArgoCD (polls GitHub every 3 min)
    │  Detects kustomization.yaml change
    │  kustomize build k8s/ → apply diff
    ▼
Kubernetes rolling update — zero downtime
```

**Key security properties:**
- No AWS_ACCESS_KEY_ID anywhere — GitHub OIDC exchanges token for short-lived credentials
- ECR tags are IMMUTABLE — `latest` never pushed, SHA tags only
- All images Trivy-scanned before push — CRITICAL/HIGH CVE = hard fail
- DB password lives only in AWS Secrets Manager → synced by ESO to in-cluster Secret

---

## Secret Management Flow

```
AWS Secrets Manager
  /bookstore/db-credentials
  {"DB_USERNAME":"admin","DB_PASSWORD":"..."}
        │
        │  IRSA (IAM Role for Service Account — no static keys)
        ▼
External Secrets Operator
  Syncs every 1 hour → Kubernetes Secret "db-secret"
        │
        ├─ mysql-0 pod (MYSQL_ROOT_PASSWORD)
        └─ backend pods (DB_USERNAME, DB_PASSWORD env vars)
```

---

## Infrastructure — What Terraform Creates

| Module | Resources |
|--------|-----------|
| `network` | VPC, 8 subnets, IGW, NAT Gateway, route tables |
| `security` | NLB SG (80/443 public) + RDS SG (3306 VPC-only) |
| `acm` | ACM certificate for `b17facebook.xyz` + `*.b17facebook.xyz` |
| `rds` | RDS MySQL 8.0 Multi-AZ, password in Secrets Manager |
| `ecr` | `bookstore-frontend` + `bookstore-backend` repos |
| `eks` | EKS 1.31 cluster, OIDC provider, t3.medium node group |
| `route53` | Private hosted zone for RDS internal DNS |

---

## Quick Start

```bash
# 1. Bootstrap Terraform state
./scripts/bootstrap-tf-state.sh us-west-1

# 2. Provision AWS infrastructure
terraform init && terraform apply

# 3. Install cluster components (EBS CSI, cert-manager, ESO, nginx, ArgoCD)
python eks_bootstrap.py

# 4. Push to main → approve deploy stage in GitHub Actions
# → ArgoCD deploys automatically
```

See `IMPLEMENTATION_GUIDE.md` for the complete step-by-step guide.
