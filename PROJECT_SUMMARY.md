# Bookstore Project — Complete Summary

> **Region:** us-west-1 (N. California)
> **Last updated:** 2026-06-17
> **Status:** EKS path only — EC2/ASG path removed

---

## 1. What This Project Is

A production-reference three-tier bookstore web application deployed on AWS. The application lets users browse and manage books via a React frontend that calls a Node.js REST API, which reads and writes to a MySQL database.

The infrastructure is fully defined in Terraform, the application runs on Kubernetes (EKS), secrets are managed by AWS Secrets Manager, and deployments are GitOps-driven via ArgoCD triggered by a GitHub Actions DevSecOps pipeline.

---

## 2. Architecture

```
Internet
    │
    ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  VPC  170.20.0.0/16  —  us-west-1                                        │
│                                                                          │
│  Public Subnets (170.20.1–2.0/24)                                        │
│  ┌──────────────────────┐   ┌─────────────────────┐                      │
│  │  Internet Gateway    │   │  NAT Gateway        │                      │
│  │  Nginx Ingress NLB   │   │  (outbound only)    │                      │
│  └──────────┬───────────┘   └─────────────────────┘                      │
│             │ HTTPS (443) / HTTP → HTTPS redirect                        │
│  Private Subnets — App Tier (170.20.3–6.0/24)                            │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │  EKS Managed Node Group  —  t3.medium  —  min:1 / desired:1 / max:4│  │
│  │                                                                    │  │
│  │  bookstore namespace                                               │  │
│  │  ┌──────────────────┐   ┌───────────────────┐   ┌─────────────┐   │  │
│  │  │  Frontend Pods   │   │  Backend Pods     │   │  MySQL Pod  │   │  │
│  │  │  React + Nginx   │──▶│  Node.js/Express  │──▶│  StatefulSet│   │  │
│  │  │  replicas: 2     │   │  replicas: 2      │   │  (dev only) │   │  │
│  │  │  port: 8080      │   │  port: 3000       │   │  port: 3306 │   │  │
│  │  └──────────────────┘   └───────────────────┘   └─────────────┘   │  │
│  │                                   │ (prod: RDS endpoint)           │  │
│  └────────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  Private Subnets — Data Tier (170.20.7–8.0/24)                           │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │  RDS MySQL 8.0  —  db.t3.micro  —  Multi-AZ  —  deletion-protect  │  │
│  │  Master password managed by AWS Secrets Manager (no plaintext)     │  │
│  └────────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  ┌──────────────────────┐   ┌──────────────────────────────────────────┐ │
│  │  Amazon ECR          │   │  AWS Secrets Manager                     │ │
│  │  bookstore-frontend  │   │  /bookstore/db-credentials               │ │
│  │  bookstore-backend   │   │  (DB_USERNAME + DB_PASSWORD)             │ │
│  └──────────────────────┘   └──────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────────┘
```

### Traffic Flow

| Step | From | To | Protocol |
|------|------|----|----------|
| 1 | User | Nginx Ingress NLB (public) | HTTPS |
| 2 | Nginx Ingress | Frontend pods (port 8080) | HTTP |
| 3 | Frontend | Backend pods (port 3000) | HTTP (internal) |
| 4 | Backend | RDS MySQL (port 3306) | TCP |

---

## 3. Tech Stack

| Layer | Technology | Version |
|-------|-----------|---------|
| Frontend | React + Nginx Alpine | React 18, Nginx 1.25 |
| Backend | Node.js + Express + mysql2 | Node.js 18 |
| Database | MySQL | 8.0 |
| Container Registry | Amazon ECR | — |
| Orchestration | Kubernetes on Amazon EKS | 1.31 |
| Infrastructure as Code | Terraform + AWS provider | ≥ 1.7 / ~5.0 |
| GitOps | ArgoCD | stable |
| CI/CD | GitHub Actions | — |
| Secret Management | AWS Secrets Manager + ESO | — |
| TLS | cert-manager + Let's Encrypt | v1.14 |
| Ingress | Nginx Ingress Controller | 4.9.1 |
| Security Scanning | Gitleaks, Semgrep, npm audit, Trivy | — |

---

## 4. Repository Structure

```
aws_three_tier_code-main/
│
├── main.tf                        # Root Terraform — all module wiring
├── github-oidc-trust.json         # Trust policy for GitHub OIDC IAM role
├── github-oidc-policy.json        # Permissions policy for GitHub OIDC role
│
├── modules/
│   ├── network/                   # VPC, subnets, IGW, NAT, route tables
│   ├── security/                  # Security groups: ALB ingress + RDS only
│   ├── acm/                       # ACM TLS certificate (b17facebook.xyz)
│   ├── rds/                       # RDS MySQL 8.0 Multi-AZ
│   ├── ecr/                       # ECR repos: bookstore-frontend, bookstore-backend
│   ├── eks/                       # EKS cluster 1.31, OIDC provider, node group
│   ├── route53/                   # Private hosted zone for RDS internal DNS
│   ├── bastion/                   # (deprecated, kept in tree, not wired)
│   ├── load_balancers/            # (deprecated, kept in tree, not wired)
│   ├── launch_templates/          # (deprecated, kept in tree, not wired)
│   └── asg/                       # (deprecated, kept in tree, not wired)
│
├── k8s/
│   ├── namespace.yaml             # bookstore namespace
│   ├── kustomization.yaml         # Kustomize root — image tags updated by CI
│   ├── configmaps/
│   │   └── backend-config.yaml   # DB_HOST, DB_PORT, DB_NAME, APP_PORT
│   ├── secrets/
│   │   ├── external-secret.yaml  # ESO ClusterSecretStore + ExternalSecret (prod)
│   │   └── db-secret.yaml        # Static secret (dev/local only — never commit real values)
│   ├── database/
│   │   ├── mysql-statefulset.yaml # In-cluster MySQL (dev only)
│   │   ├── mysql-service.yaml    # Headless service for StatefulSet DNS
│   │   └── mysql-init-configmap.yaml
│   ├── backend/
│   │   ├── deployment.yaml       # Backend Deployment (non-root, read-only FS)
│   │   ├── service.yaml
│   │   └── hpa.yaml              # HPA: CPU 70%, min 2 / max 5
│   ├── frontend/
│   │   ├── deployment.yaml       # Frontend Deployment (non-root, read-only FS)
│   │   ├── service.yaml
│   │   └── hpa.yaml
│   ├── ingress/
│   │   └── ingress.yaml          # Nginx Ingress + cert-manager TLS
│   ├── network-policy/
│   │   └── network-policy.yaml   # Default-deny + per-tier allow rules
│   ├── pdb/
│   │   └── pdb.yaml              # PodDisruptionBudgets
│   └── argocd/
│       └── application.yaml      # ArgoCD Application manifest
│
├── .github/workflows/
│   ├── ci-cd.yml                  # DevSecOps app pipeline (4 stages)
│   └── terraform.yml              # Terraform plan / apply pipeline
│
├── backend/
│   ├── index.js                   # Express CRUD API (/books)
│   ├── Dockerfile
│   ├── package.json
│   └── test.sql                   # Schema seed for local dev
│
├── client/
│   ├── src/pages/config.js        # API_BASE_URL (set for local dev)
│   ├── nginx.conf
│   ├── Dockerfile                 # Multi-stage: npm build → Nginx
│   └── package.json
│
├── scripts/
│   ├── build-and-push.sh          # Manual ECR push helper
│   └── bootstrap-tf-state.sh      # Creates S3 bucket + DynamoDB lock table
│
├── README.md
├── IMPLEMENTATION_GUIDE.md        # Step-by-step deployment guide
├── FUTURE.md                      # ADRs, known limitations, roadmap
└── PROJECT_SUMMARY.md             # ← this file
```

---

## 5. Terraform Infrastructure

### What `terraform apply` Creates

| Module | AWS Resources |
|--------|--------------|
| `network` | VPC `170.20.0.0/16`, 2 public + 6 private subnets across `us-west-1a/b`, IGW, NAT Gateway, route tables |
| `security` | 2 security groups: `alb_frontend` (HTTP/HTTPS from 0.0.0.0/0) and `rds` (MySQL 3306 from VPC CIDR) |
| `acm` | ACM certificate for `b17facebook.xyz` + `*.b17facebook.xyz` (DNS validation) |
| `rds` | MySQL 8.0, `db.t3.micro`, Multi-AZ, 25 GB, 7-day backups, deletion-protected, password in Secrets Manager, Performance Insights **off** |
| `ecr` | `bookstore-frontend` and `bookstore-backend` repos, 10-image retention |
| `eks` | EKS 1.31 cluster, OIDC provider, managed node group (`t3.medium`, `AL2_x86_64`, min:1 / desired:1 / max:4) |
| `route53` | Private hosted zone `rds.com` with CNAME `book.rds.com → RDS endpoint` |

### Root Outputs

```bash
terraform output vpc_id
terraform output rds_endpoint
terraform output rds_secret_arn       # sensitive
terraform output frontend_repo_url
terraform output backend_repo_url
terraform output eks_cluster_name
terraform output eks_cluster_endpoint
terraform output eks_oidc_provider_arn
```

### Subnet Layout

| Index | CIDR | AZ | Purpose |
|-------|------|----|---------|
| public[0] | 170.20.1.0/24 | us-west-1a | IGW / NLB |
| public[1] | 170.20.2.0/24 | us-west-1b | IGW / NLB |
| private[0] | 170.20.3.0/24 | us-west-1a | EKS nodes |
| private[1] | 170.20.4.0/24 | us-west-1b | EKS nodes |
| private[2] | 170.20.5.0/24 | us-west-1a | EKS nodes |
| private[3] | 170.20.6.0/24 | us-west-1b | EKS nodes |
| private[4] | 170.20.7.0/24 | us-west-1a | RDS |
| private[5] | 170.20.8.0/24 | us-west-1b | RDS |

---

## 6. Kubernetes Manifests

### Cluster Add-ons (installed manually, not in Terraform)

| Add-on | Installed via | Namespace |
|--------|--------------|-----------|
| EBS CSI Driver | `aws eks create-addon` | kube-system |
| gp3 StorageClass | `kubectl apply` | cluster-wide |
| cert-manager v1.14 | Helm | cert-manager |
| External Secrets Operator 0.9.13 | Helm | external-secrets |
| Nginx Ingress Controller 4.9.1 | Helm | ingress-nginx |
| ArgoCD | `kubectl apply` | argocd |

### Workloads in `bookstore` namespace

| Resource | Replicas | Image | Port |
|----------|----------|-------|------|
| `frontend` Deployment | 2 | `bookstore-frontend:<sha>` | 8080 |
| `backend` Deployment | 2 | `bookstore-backend:<sha>` | 3000 |
| `mysql` StatefulSet | 1 | `mysql:8.0` | 3306 (dev only) |

### Security Posture of All Pods

- `runAsNonRoot: true` — UID 1001 (backend) / 101 (frontend)
- `readOnlyRootFilesystem: true` — `/tmp` mounted as emptyDir for writes
- `allowPrivilegeEscalation: false`
- `capabilities: drop: ["ALL"]`
- `seccompProfile: RuntimeDefault`

### NetworkPolicy Rules

| Pod | Ingress allowed from | Egress allowed to |
|-----|---------------------|-------------------|
| frontend | ingress-nginx namespace | backend:3000, DNS:53 |
| backend | frontend pods, ingress-nginx | mysql:3306, DNS:53 |
| mysql | backend pods | DNS:53 |
| (default) | **deny all** | **deny all** |

### Ingress

- Host `bookstore.b17facebook.xyz` → `frontend-service:80`
- Host `api.bookstore.b17facebook.xyz` → `backend-service:80`
- TLS via `cert-manager.io/cluster-issuer: letsencrypt-prod`
- HTTP → HTTPS force-redirect enforced

### HPA

Both `backend` and `frontend` scale on CPU target 70%, min 2 replicas, max 5.

---

## 7. CI/CD Pipeline

### App Pipeline — `.github/workflows/ci-cd.yml`

Triggers on push / PR to `main`.

```
Stage 0 — Secret Scan (Gitleaks, full git history)
    │ fail fast on any detected secret
    ▼
Stage 1 — SAST & Audit           Stage 2 — Lint & Validate
  npm audit --audit-level=high     ESLint (zero warnings)
  Semgrep (nodejs + owasp-top-10)  kubeval k8s manifests
    └──────────────┬───────────────────────┘
                   │ both must pass
                   ▼
         Stage 3 — Build → Trivy Scan → ECR Push  (main branch only)
           docker build backend
           Trivy scan → SARIF uploaded to GitHub Security tab
           CRITICAL/HIGH unfixed CVE = hard fail, image not pushed
           docker push ECR  (tagged: <sha8> + latest)
           same for frontend
                   │
          Manual approval gate (GitHub Environment: production)
                   │
         Stage 4 — GitOps image-tag update
           kustomize edit set image bookstore-backend=<registry>:<sha8>
           kustomize edit set image bookstore-frontend=<registry>:<sha8>
           git commit k8s/kustomization.yaml
           git push (GITHUB_TOKEN — does NOT re-trigger pipeline)
                   │
                   ▼ ArgoCD polls repo (~3 min)
           ArgoCD detects changed kustomization.yaml
           kustomize build k8s/ → apply diff to bookstore namespace
           Pods rolling-restart with new image
           selfHeal: true — reverts any manual kubectl drift
```

### Terraform Pipeline — `.github/workflows/terraform.yml`

Triggers on push / PR to `main` when any `.tf` file changes.

```
tfsec (IaC static security analysis)
terraform fmt -check
terraform init
terraform validate
terraform plan  → posts plan diff as PR comment
terraform apply (main branch push only, auto-approve)
```

### Authentication — GitHub OIDC

No static `AWS_ACCESS_KEY_ID` or `AWS_SECRET_ACCESS_KEY` anywhere. The pipeline exchanges a GitHub OIDC token for short-lived AWS credentials via IAM role assumption (`bookstore-github-oidc-role`). The role trust policy is scoped to the specific repository.

Required GitHub Secrets:

| Secret | Purpose |
|--------|---------|
| `AWS_ACCOUNT_ID` | ECR registry URL construction |
| `AWS_ROLE_ARN` | OIDC role to assume |
| `API_URL` | Backend URL injected into React build (`REACT_APP_API_URL`) |
| `SEMGREP_APP_TOKEN` | Optional — Semgrep Cloud integration |

---

## 8. Secret Management

```
AWS Secrets Manager
  /bookstore/db-credentials
  { "DB_USERNAME": "admin", "DB_PASSWORD": "..." }
        │
        │  IRSA — IAM Role for Service Account
        │  (bookstore-eso-role bound to external-secrets-sa)
        ▼
External Secrets Operator
  ClusterSecretStore "aws-secretsmanager" (region: us-west-1)
  ExternalSecret "db-secret" — refreshInterval: 1h
        │
        ▼
k8s Secret "db-secret" in bookstore namespace
  DB_USERNAME / DB_PASSWORD (never in git, never in pipeline)
        │
        ▼
Backend pods mount as env vars via secretKeyRef
```

RDS master password is also managed by AWS Secrets Manager automatically via `manage_master_user_password = true` in Terraform. The secret ARN is exposed as `terraform output rds_secret_arn`.

---

## 9. Security Controls

| Control | Implementation |
|---------|---------------|
| Secret detection | Gitleaks scans every commit + full git history |
| SAST | Semgrep with `nodejs` + `owasp-top-ten` + `secrets` rule packs |
| Dependency CVEs | `npm audit --audit-level=high` on backend and frontend |
| Container CVEs | Trivy blocks ECR push on any CRITICAL/HIGH unfixed CVE |
| IaC security | tfsec on every Terraform change |
| No static AWS keys | GitHub OIDC → short-lived IAM role credentials |
| Secrets in cluster | ESO pulls from Secrets Manager; secret never touches pipeline or git |
| Non-root containers | All pods run as UID 1001 or 101 |
| Read-only filesystems | `readOnlyRootFilesystem: true`; `/tmp` as emptyDir |
| Dropped capabilities | `capabilities: drop: ["ALL"]` on all containers |
| Pod-to-pod isolation | Kubernetes NetworkPolicy: default-deny-all + per-tier allow |
| TLS everywhere | cert-manager + Let's Encrypt; HTTP force-redirects to HTTPS |
| Manual deploy gate | GitHub Environment `production` requires reviewer approval |
| IMDSv2 | Enforced on EC2 node metadata endpoint (in EKS node group config) |
| RDS encryption | `storage_encrypted = true` using AWS-managed KMS key |
| VPC isolation | RDS in dedicated private subnets (170.20.7–8.0/24), no public access |

---

## 10. Changes Made During This Session

### Bug Fixes Applied (from `terraform apply` errors)

| Error | Root Cause | Fix Applied |
|-------|-----------|-------------|
| Invalid AMI IDs | AMIs were region-specific (wrong region) | Updated both to `ami-04b70fa74e45c3917` (Ubuntu 22.04, us-east-1 at the time) |
| vCPU limit exceeded | 9 vCPUs requested vs 8-vCPU account limit | `asg_min_size` + `asg_desired_capacity` → 1 each |
| EKS node AMI rejected | Missing `ami_type` in node group | Added `ami_type = "AL2_x86_64"` to `aws_eks_node_group` |
| ACM certificate race | ALB HTTPS listener created before cert validated | Added `depends_on = [module.acm]` on `module "alb"` |
| Performance Insights rejected | Not supported on `db.t3.micro` | `performance_insights_enabled = false`, removed retention line |

### EC2/ASG Path Removed (EKS-only)

Removed from `main.tf`:
- `module "alb"` (EC2 load balancers)
- `module "launch_templates"` (EC2 AMI configs)
- `module "autoscaling"` (ASGs)
- `module "bastion"` (SSH bastion host)
- `aws_iam_role.ec2_app_role` + policy + instance profile
- `aws_ssm_parameter.rds_secret_arn`
- `variable "allowed_ssh_cidr"`

Simplified modules:
- `modules/security/`: removed `frontend_instance`, `alb_backend`, `backend_instance`, `bastion` SGs and all their rules; RDS now allows MySQL from VPC CIDR `170.20.0.0/16`
- `modules/route53/`: removed public hosted zone and ALB DNS records; kept only RDS private zone

### EKS Cluster Sized to Minimum

```hcl
node_min_size     = 1
node_desired_size = 1
node_max_size     = 4
```

vCPU usage: 1 × t3.medium (2 vCPUs) + RDS = **2 vCPUs** — well under any account limit.

### Region Changed: us-east-1 → us-west-1

Every file updated:

| File | What changed |
|------|-------------|
| `main.tf` | S3 backend region, `aws_region` default, all subnet AZs |
| `.github/workflows/ci-cd.yml` | `AWS_REGION`, `ECR_REGISTRY` URL |
| `.github/workflows/terraform.yml` | `AWS_REGION` |
| `k8s/secrets/external-secret.yaml` | Secrets Manager `region` |
| `k8s/kustomization.yaml` | ECR registry hostname |
| `modules/network/variables.tf` | Default region, AZ comments |
| `github-oidc-policy.json` | ECR + EKS ARN regions |
| `IMPLEMENTATION_GUIDE.md` | All region/AZ/URL references |
| `README.md` | All region/AZ/URL references |

**Note:** us-west-1 has only 2 AZs (`us-west-1a`, `us-west-1b`). The 6 private subnets alternate between these two — same topology, different region.

---

## 11. Open Items / Known Limitations

### Must Do Before First Apply

- [ ] Run `scripts/bootstrap-tf-state.sh us-west-1` to create S3 bucket + DynamoDB lock table
- [ ] Fill in `backend "s3"` block in `main.tf` with the bucket name and table name printed by the script
- [ ] Replace `YOUR_ORG/YOUR_REPO` in `k8s/argocd/application.yaml` with your actual GitHub repo URL
- [ ] Replace `ACCOUNT_ID` in `k8s/kustomization.yaml` with your 12-digit AWS account ID

### Infrastructure

- **Terraform remote state not enabled** — `backend "s3"` block bucket/table values are empty strings. Bootstrap script must run first.
- **EKS add-ons are manual** — EBS CSI, cert-manager, ESO, and Nginx Ingress are not managed by Terraform; they must be installed via `aws eks create-addon` and Helm after cluster creation.
- **No gp3 StorageClass manifest** — must `kubectl apply` the StorageClass inline after EBS CSI is active.

### Application

- **In-cluster MySQL is dev-only** — `k8s/database/mysql-statefulset.yaml` must not be applied to production; change `DB_HOST` in `k8s/configmaps/backend-config.yaml` to the RDS endpoint for prod.
- **No graceful shutdown** — backend has no `process.on('SIGTERM')` handler; in-flight requests may drop on pod termination.
- **No integration tests** — backend has no automated test suite beyond `npm audit`.

---

## 12. Planned Improvements (from FUTURE.md)

### Short Term
1. Kustomize dev/staging/prod overlays (replaces manual `ACCOUNT_ID` substitution)
2. Add `k8s/storageclass/gp3.yaml` manifest
3. Manage EKS add-ons in Terraform (`helm_release` in a `modules/eks-addons/` module)
4. Enable Terraform remote state (bootstrap script exists; just needs to be run)

### Medium Term
5. GitOps already partially implemented (ArgoCD + kustomize image tag commit); complete by removing any remaining direct `kubectl` calls
6. Helm chart packaging for environment-specific config
7. Observability stack: Prometheus + Grafana + Loki

### Long Term
8. Multi-region active-passive failover (us-west-1 primary + us-west-2 DR)
9. Service mesh (Istio or AWS App Mesh) for mTLS + canary deployments
10. Karpenter for Spot Instance node provisioning

---

## 13. How to Deploy (Quick Reference)

```bash
# 1. Bootstrap remote state (one-time)
./scripts/bootstrap-tf-state.sh us-west-1
# Fill in main.tf backend block with printed values

# 2. Provision AWS infrastructure
terraform init
terraform plan
terraform apply

# 3. Configure kubectl
aws eks update-kubeconfig --name bookstore-eks --region us-west-1

# 4. Install EKS add-ons (one-time)
aws eks create-addon --cluster-name bookstore-eks --addon-name aws-ebs-csi-driver --region us-west-1
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

helm repo add jetstack https://charts.jetstack.io
helm install cert-manager jetstack/cert-manager -n cert-manager --create-namespace --version v1.14.4 --set installCRDs=true

helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets -n external-secrets --create-namespace --version 0.9.13

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx --create-namespace --set controller.service.type=LoadBalancer

kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 5. Store DB credentials
aws secretsmanager create-secret \
  --name /bookstore/db-credentials \
  --region us-west-1 \
  --secret-string '{"DB_USERNAME":"admin","DB_PASSWORD":"<strong-password>"}'

# 6. Apply ArgoCD application (one-time, after updating k8s/argocd/application.yaml)
kubectl apply -f k8s/argocd/application.yaml

# 7. Push to main branch → GitHub Actions pipeline runs automatically
#    Manual approval required before Stage 4 deploys to EKS
```

---

## 14. Component Ownership

| Component | Managed by | Location |
|-----------|-----------|----------|
| VPC, subnets, NAT, IGW | Terraform | `modules/network/` |
| Security groups (ingress ALB + RDS) | Terraform | `modules/security/` |
| ACM certificate | Terraform | `modules/acm/` |
| RDS MySQL (prod) | Terraform | `modules/rds/` |
| ECR repositories | Terraform | `modules/ecr/` |
| EKS cluster + node group | Terraform | `modules/eks/` |
| Route 53 private zone (RDS DNS) | Terraform | `modules/route53/` |
| EBS CSI driver | `aws eks create-addon` | one-time manual |
| gp3 StorageClass | `kubectl apply` | one-time manual |
| cert-manager | Helm | one-time manual |
| External Secrets Operator | Helm | one-time manual |
| Nginx Ingress Controller | Helm | one-time manual |
| ArgoCD | `kubectl apply` | one-time manual |
| DB credentials secret | AWS Secrets Manager | one-time manual |
| k8s manifests + image tags | ArgoCD + CI/CD pipeline | `k8s/` |
| Docker images | GitHub Actions | `.github/workflows/ci-cd.yml` |
| Terraform state | S3 + DynamoDB | auto after bootstrap |
