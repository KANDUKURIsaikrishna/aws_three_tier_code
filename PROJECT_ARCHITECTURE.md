# Bookstore — Complete Project Architecture & Implementation Guide

**Stack:** React · Node.js · MySQL · Kubernetes (EKS) · Terraform · GitHub Actions · ArgoCD · Argo Rollouts · Prometheus · Grafana  
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

The infrastructure is fully automated: Terraform provisions AWS resources and installs all cluster add-ons (cert-manager, ESO, ingress-nginx, ArgoCD, Prometheus, Argo Rollouts) via the `eks-addons` module. `eks_bootstrap.py` handles the remaining cluster-specific steps (IRSA, ClusterIssuer, ArgoCD Application). GitHub Actions builds and deploys every commit automatically via ArgoCD, with backend releases delivered as Argo Rollouts canaries.

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
│         │  │ Deploym. │  │ Argo Rollout│  │         │      │
│         │  └──────────┘  └──────┬──────┘  │         │      │
│         │                       │ :3306   │         │      │
│         │              ┌────────▼──────┐  │         │      │
│         │              │  mysql-0      │  │         │      │
│         │              │ (StatefulSet) │  │         │      │
│         │              └───────────────┘  │         │      │
│         └──────────────────────────────────┘         │      │
│                                                      │      │
│         (zero monitoring pods in EKS cluster)         │      │
│                                                      │      │
│  Public Subnet (monitoring EC2 t3.small)             │      │
│  ┌─────────────────────────────────────────────┐     │      │
│  │ Elastic IP  ← Grafana :3000 / Prom :9090   │     │      │
│  │ Docker Compose:                             │     │      │
│  │   prometheus   (scrapes nodes :9100 + KSM) │     │      │
│  │   loki         (:3100, VPC-only inbound)   │     │      │
│  │   grafana      (admin pass from SecretsMgr)│     │      │
│  │   kube-state-metrics (kubeconfig → EKS API)│     │      │
│  └─────────────────────────────────────────────┘     │      │
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
  ECR            — Docker image registry (bookstore-backend, bookstore-frontend)
  ACM            — TLS certificate for *.b17facebook.xyz
  Secrets Manager — DB credentials (/bookstore/db-credentials), Grafana password (/bookstore/grafana-admin)
  IAM/OIDC       — Keyless auth for GitHub Actions and ESO (IRSA); EKS access entry for monitoring EC2
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
| Nodes | min 1 / desired 1 / max 2 |
| Node placement | private subnets (3–6) |
| Control plane logs | api, audit, authenticator, controllerManager, scheduler |
| OIDC provider | enabled (required for IRSA) |

**IAM roles created by Terraform:**
- `bookstore-eks-cluster-role` — EKS control plane role
- `bookstore-eks-node-role` — EC2 node role with `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`, `AmazonEC2ContainerRegistryReadOnly`, `AmazonEBSCSIDriverPolicy`

**`modules/eks/output.tf`** exports: `cluster_name`, `cluster_endpoint`, `cluster_ca_certificate` (sensitive), `oidc_provider_arn`, `oidc_provider_url`, `node_group_role_arn`, `node_role_name`.

### 3.3 EKS Add-ons (`modules/eks-addons/`)

All cluster platform components are managed by Terraform as `helm_release` resources. A `provider "helm"` block in root `main.tf` authenticates via `aws eks get-token` (exec auth — no static credentials).

| Component | Resource type | Namespace | Key settings |
|-----------|--------------|-----------|-------------|
| EBS CSI driver | `aws_eks_addon` | `kube-system` | — |
| cert-manager | `helm_release` | `cert-manager` | v1.14.4, 1 replica |
| External Secrets Operator | `helm_release` | `external-secrets` | 1 replica |
| ingress-nginx | `helm_release` | `ingress-nginx` | v4.9.1, 1 replica, PDB minAvailable=1 |
| ArgoCD | `helm_release` | `argocd` | 1 replica each component |
| argo-rollouts | `helm_release` | `argo-rollouts` | 1 replica |

> **No monitoring Helm charts in EKS.** Prometheus, Grafana, and Loki run on a dedicated EC2 instance (`modules/monitoring-ec2/`). node-exporter and Fluent Bit are installed as AL2 systemd services via the EKS node group launch template — not as Kubernetes pods. kube-state-metrics runs as a Docker container on the monitoring EC2 and authenticates to the K8s API via an EKS access entry.

### 3.9 Monitoring EC2 (`modules/monitoring-ec2/`)

A dedicated `t3.small` EC2 instance in the public subnet hosts the full observability stack:

| Service | Port | Accessible from |
|---------|------|----------------|
| Grafana | 3000 | `monitoring_admin_cidr` (default: all) — restrict to your IP |
| Prometheus | 9090 | `monitoring_admin_cidr` |
| Loki | 3100 | VPC CIDR only (Fluent Bit on EKS nodes pushes here) |
| kube-state-metrics | 8080 | Docker internal network only (Prometheus scrapes via Compose network) |

**EKS node metrics (node-exporter on port 9100):** Prometheus discovers node IPs every 5 minutes via `aws ec2 describe-instances` and writes Prometheus `file_sd_configs` target files. A Security Group rule allows inbound 9100 from the monitoring EC2's SG to the EKS cluster SG.

**Automation at first boot:**
- Kubeconfig generated via `aws eks update-kubeconfig`
- Grafana admin password fetched from Secrets Manager
- Prometheus alerting rules provisioned (NodeDown, HighCPU, HighMemory, PodCrashLooping)
- Grafana dashboards auto-imported via API (Node Exporter Full #1860, K8s cluster #315)

### 3.4 RDS

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

### 3.5 ECR

Two repositories, both `IMMUTABLE` (tags cannot be overwritten — prevents accidental overwrites):

| Repository | Image |
|------------|-------|
| `bookstore-backend` | Node.js API |
| `bookstore-frontend` | nginx serving React build |

Retention policy: keep the 10 most recent images; older ones are automatically deleted.

### 3.6 ACM (TLS Certificate)

Certificate provisioned for:
- `b17facebook.xyz` (primary)
- `*.b17facebook.xyz` (wildcard SAN)

Used by ingress-nginx for HTTPS termination via cert-manager (Let's Encrypt `letsencrypt-prod` ClusterIssuer).

### 3.7 Route 53

**Public hosted zone** (`b17facebook.xyz`) — two A records, both aliased to the same NLB:

| Record | Type | Target |
|--------|------|--------|
| `bookstore.b17facebook.xyz` | A (ALIAS) | NLB hostname |
| `api.bookstore.b17facebook.xyz` | A (ALIAS) | NLB hostname |

**Private hosted zone** — created by the `route53` module for internal RDS endpoint resolution.

> A wildcard `*.b17facebook.xyz` only matches one subdomain level. It covers `bookstore.b17facebook.xyz` but NOT `api.bookstore.b17facebook.xyz` (two levels). Both records must be created explicitly.

### 3.8 IAM — GitHub Actions OIDC (No Static Keys)

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

| SG | Inbound | Outbound | Purpose |
|----|---------|----------|---------|
| `bookstore-alb-frontend-sg` | 0.0.0.0/0 → 80, 443 | 0.0.0.0/0 all | Internet-facing NLB |
| `bookstore-rds-sg` | 170.20.0.0/16 → 3306 | **none** | RDS access from VPC only; no egress (RDS never initiates connections) |
| `bookstore-monitoring-sg` | `monitoring_admin_cidr` → 3000, 9090; VPC CIDR → 3100 | 0.0.0.0/0 all | Monitoring EC2; Loki push restricted to VPC |
| EKS cluster SG (auto) | monitoring-sg → 9100 | — | node-exporter scrape from monitoring EC2 |

---

## 5. Kubernetes Architecture

All application resources live in the `bookstore` namespace, managed by Kustomize with a base + overlays structure. Platform components (cert-manager, ESO, ingress-nginx, ArgoCD, Prometheus, Argo Rollouts) have their own namespaces and are installed by Terraform.

### 5.1 Frontend

| Resource | Spec |
|----------|------|
| Deployment | 1 replica (dev) / HPA-managed 1–3 (prod), image `bookstore-frontend:<sha>` |
| Container | nginx 1.27-alpine, port 8080 |
| HPA | min 1, max 3 replicas; scales on 70% CPU (prod overlay only) |
| PDB | at least 1 pod always available |
| Security | `readOnlyRootFilesystem: true`, `runAsNonRoot: true`, capabilities dropped |
| Volumes | `emptyDir` at `/tmp`, `/var/cache/nginx`, `/var/run` |

### 5.2 Backend

| Resource | Spec |
|----------|------|
| **Argo Rollout** | 1 replica (dev) / HPA-managed 1–5 (prod), image `bookstore-backend:<sha>` |
| Container | Node.js 22-alpine, port 3000 (named `http`) |
| Delivery | Canary: 10% → 30s pause → 50% → 30s pause → 100% |
| HPA | min 1, max 5 replicas; scales on 70% CPU or 80% Memory (prod overlay only) |
| PDB | at least 1 pod always available |
| Security | `readOnlyRootFilesystem: true`, `runAsNonRoot: true`, `runAsUser: 1001` |
| Config | `backend-config` ConfigMap (`DB_HOST`, `DB_PORT`, `DB_NAME`, `APP_PORT`) |
| Secrets | `db-secret` (`DB_USERNAME`, `DB_PASSWORD`) — never stored in git |
| Resource limits (base/dev) | requests 50m CPU / 64Mi RAM; limits 250m CPU / 128Mi RAM |
| Resource limits (prod overlay) | requests 128m CPU / 128Mi RAM; limits 500m CPU / 256Mi RAM |

**API endpoints:**

| Method | Path | Description |
|--------|------|-------------|
| GET | `/` | Health check — returns `"hello"` |
| GET | `/books` | List all books |
| POST | `/books` | Add a book |
| PUT | `/books/:id` | Update a book |
| DELETE | `/books/:id` | Delete a book |
| GET | `/metrics` | Prometheus metrics (prom-client) |

**Backend code structure:**
- `backend/app.js` — `export function createApp(db)` factory; all routes + `/metrics` endpoint; injectable mock db for testing
- `backend/index.js` — creates real MySQL connection, calls `createApp(db)`, starts server
- `backend/__tests__/books.test.js` — 6 vitest tests using `vi.fn()` mock db; no real database required

### 5.3 MySQL (StatefulSet)

| Resource | Spec |
|----------|------|
| StatefulSet | 1 replica (`mysql-0`) |
| Container | `mysql:8.0` |
| PVC | 10 Gi, `gp3` StorageClass (EBS volume, declared in `k8s/base/storageclass/gp3.yaml`) |
| Init scripts | `/docker-entrypoint-initdb.d/init.sql` from ConfigMap |
| Root password | from `db-secret.DB_PASSWORD` |
| Database created | `test` |
| Tables | `books (id, title, desc, price, cover)` |

The PVC (`mysql-data`) is not deleted when the pod restarts — data persists across crashes and rolling updates.

### 5.4 Ingress

Handled by **ingress-nginx** (installed by Terraform). A single `Ingress` resource routes by hostname:

```yaml
bookstore.b17facebook.xyz     → frontend-service:80
api.bookstore.b17facebook.xyz → backend-service:80
```

- Forces HTTPS redirect (HTTP 301 → HTTPS)
- TLS certificate managed by **cert-manager** via `letsencrypt-prod` ClusterIssuer
- Certificate stored in `bookstore-tls` Secret in the `bookstore` namespace

### 5.5 Observability

**No monitoring pods run in the EKS cluster.** The full observability stack lives on a dedicated EC2 instance. Only data collectors are installed on EKS nodes — as AL2 systemd services via the node group launch template, not as Kubernetes pods.

**EC2 monitoring stack (Docker Compose, `t3.small`):**

| Container | Image | Port | Purpose |
|-----------|-------|------|---------|
| prometheus | `prom/prometheus:v2.53.0` | 9090 | Scrapes node-exporter (file_sd, port 9100) + kube-state-metrics (localhost:8080). 15-day retention. |
| loki | `grafana/loki:3.0.0` | 3100 | Log aggregation. Fluent Bit on EKS nodes pushes here. boltdb-shipper/filesystem storage. |
| grafana | `grafana/grafana:11.0.0` | 3000 | Dashboards auto-provisioned (datasources) + auto-imported (Node Exporter Full, K8s cluster) |
| kube-state-metrics | `kube-state-metrics:v2.13.0` | 8080 (internal) | K8s resource metrics. Mounts kubeconfig; authenticates via EKS access entry. |

**EKS node agents (systemd, not K8s pods):**

| Service | Binary | Port | Role |
|---------|--------|------|------|
| node-exporter | v1.8.2 | 9100 | Host-level metrics (CPU, memory, disk, network) |
| fluent-bit | latest AL2 pkg | — | Tails `/var/log/containers/*.log`; pushes to Loki on EC2 |

**Prometheus target discovery:**
- `update-prom-targets.sh` runs every 5 minutes (cron) on the monitoring EC2
- Queries `aws ec2 describe-instances --filters "Name=tag:eks:cluster-name,Values=bookstore-eks"` to get current node IPs
- Writes Prometheus `file_sd_configs` JSON files; Prometheus hot-reloads without restart

**Alerting rules** (`/opt/monitoring/prometheus/rules/bookstore.yml`):

| Alert | Condition | Severity |
|-------|-----------|---------|
| NodeDown | `up{job="node-exporter"} == 0` for 5m | critical |
| HighCPUUsage | CPU > 80% for 10m | warning |
| HighMemoryUsage | Memory > 85% for 10m | warning |
| PodCrashLooping | restart rate > 3 in 15m for 5m | warning |
| KubeStateMetricsDown | `up{job="kube-state-metrics"} == 0` for 5m | critical |

**Backend metrics** (`backend/app.js` with `prom-client`):
- `http_requests_total` — Counter by method, route, status
- `http_request_duration_seconds` — Histogram of response times
- Default Node.js process metrics (memory, CPU, GC, event loop lag)
- `k8s/base/monitoring/servicemonitor.yaml` is present but targets in-cluster Prometheus which no longer exists; backend metrics are still available at `/metrics` for manual scraping or future ServiceMonitor reconfiguration.

### 5.6 Image Tags and Kustomize Overlays

The `k8s/` directory uses Kustomize base + overlays:

- `k8s/base/` — all shared manifests (no image tags, no HPAs)
- `k8s/overlays/dev/` — patches replicas=1 on Rollout and Deployment
- `k8s/overlays/prod/` — adds HPAs, backend resource limits, and image tags (CI updates these)

ArgoCD watches `k8s/overlays/prod/`. Images are tagged with the first 8 characters of the git commit SHA. The CI pipeline runs `kustomize edit set image` inside `k8s/overlays/prod/` and commits `k8s/overlays/prod/kustomization.yaml`.

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

This is **re-configured on every `eks_bootstrap.py` run** (Phase 3) because the OIDC provider URL changes every time the cluster is destroyed and recreated.

---

## 7. CI/CD Pipeline

Defined in `.github/workflows/ci-cd.yml`. Triggers on every push or pull request to `main` or `improvements` branches.

```
Push/PR to main or improvements
    │
    ▼
Stage 0: Secret Scan (Gitleaks)
    │  Scans full git history for leaked keys/tokens
    │  ✗ Fails immediately if any secret found
    ▼
Stage 1: SAST & Dependency Audit
    │  npm test (vitest — 6 tests, vi.fn() mock db)   ← runs FIRST
    │  npm audit --omit=dev --audit-level=high (backend)
    │  npm audit --audit-level=critical (frontend)
    │  Semgrep: p/nodejs + p/owasp-top-ten + p/secrets
    ▼
Stage 2: Lint & Manifest Validation
    │  ESLint — zero warnings allowed (frontend)
    │  kubeconform — validates all k8s YAML against k8s 1.31 schema
    ▼
Stage 3: Build → Trivy Scan → Push
    │  (runs on main OR improvements branches)
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
    │  cd k8s/overlays/prod
    │  kustomize edit set image bookstore-backend=...:<sha8>
    │  kustomize edit set image bookstore-frontend=...:<sha8>
    │  git commit k8s/overlays/prod/kustomization.yaml
    │  git push (with GITHUB_TOKEN — does NOT re-trigger pipeline)
    ▼
ArgoCD detects commit → syncs cluster within 3 min
  Backend: Argo Rollout canary (10% → 50% → 100%)
  Frontend: Kubernetes rolling update
```

**Key security properties:**
- No AWS credentials stored in GitHub Secrets — only `AWS_ACCOUNT_ID` (not secret) and `AWS_ROLE_ARN`
- Images never pushed with the `latest` tag (ECR repos are IMMUTABLE — `latest` cannot be overwritten)
- All images scanned by Trivy before push — dirty images never reach ECR
- Tests run before audit — catching application bugs before security checks
- Secrets never in code, never in CI env, never in logs

---

## 8. GitOps with ArgoCD

ArgoCD runs in the cluster and is the **only thing that runs `kubectl apply`**. The CI pipeline never touches `kubectl`.

```
git push to main
    │
    ▼
CI Pipeline commits k8s/overlays/prod/kustomization.yaml
  with new image SHA
    │
    ▼
ArgoCD polls GitHub repo every 3 minutes
    │ Detects kustomization.yaml changed
    ▼
ArgoCD runs: kustomize build k8s/overlays/prod/
    │ Renders all manifests with new image tags
    ▼
ArgoCD applies diff to cluster
    │ Only changed resources are updated
    ▼
Backend: Argo Rollout canary
    │ 10% traffic → new version (30s)
    │ 50% traffic → new version (30s)
    │ 100% traffic → new version
    │ Auto-rollback on pod failures
    ▼
Frontend: Kubernetes rolling update
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
├── main.tf                         # Root Terraform — wires all modules + helm provider
├── eks_bootstrap.py                # 8-phase cluster setup after terraform apply
├── cluster-issuer.yaml             # Let's Encrypt ClusterIssuer (applied by bootstrap Phase 2)
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
│   │   └── output.tf               # cluster_name, cluster_endpoint, cluster_ca_certificate,
│   │                               #   oidc_provider_arn, oidc_provider_url,
│   │                               #   node_group_role_arn, node_role_name
│   ├── eks-addons/
│   │   ├── main.tf                 # aws_eks_addon (EBS CSI) + helm_release for:
│   │   │                           #   cert-manager, external-secrets, ingress-nginx,
│   │   │                           #   argo-cd, kube-prometheus-stack, argo-rollouts
│   │   └── variables.tf            # cluster_name, oidc_provider_arn, region
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
│   └── security/
│       ├── main.tf
│       ├── variables.tf
│       └── output.tf
│
├── k8s/                            # All Kubernetes manifests (managed by ArgoCD + Kustomize)
│   ├── base/                       # Shared across all environments — no image tags, no HPAs
│   │   ├── kustomization.yaml      # Lists all base resources
│   │   ├── namespace.yaml          # Creates the "bookstore" namespace
│   │   ├── storageclass/
│   │   │   └── gp3.yaml            # EBS gp3 StorageClass for MySQL PVC
│   │   ├── configmaps/
│   │   │   └── backend-config.yaml # Non-secret config: DB_HOST, DB_PORT, DB_NAME, APP_PORT
│   │   ├── secrets/
│   │   │   └── external-secret.yaml # ESO ClusterSecretStore + ExternalSecret
│   │   ├── database/
│   │   │   ├── mysql-statefulset.yaml
│   │   │   ├── mysql-service.yaml
│   │   │   └── mysql-init-configmap.yaml
│   │   ├── backend/
│   │   │   ├── rollout.yaml        # Argo Rollout (canary — replaces deployment.yaml)
│   │   │   └── service.yaml        # ClusterIP :80 → :3000, port named "http"
│   │   ├── frontend/
│   │   │   ├── deployment.yaml     # Deployment (rolling update)
│   │   │   └── service.yaml        # ClusterIP :80 → :8080
│   │   ├── ingress/
│   │   │   └── ingress.yaml        # Routes by hostname; TLS via cert-manager
│   │   ├── monitoring/
│   │   │   └── servicemonitor.yaml # Prometheus scrapes backend /metrics every 30s
│   │   ├── network-policy/
│   │   │   └── network-policy.yaml # Default deny-all + explicit allow rules
│   │   └── pdb/
│   │       └── pdb.yaml            # PodDisruptionBudget: ≥1 pod always available
│   │
│   ├── overlays/
│   │   ├── dev/
│   │   │   └── kustomization.yaml  # Patches replicas=1 on Rollout + Deployment
│   │   └── prod/
│   │       ├── kustomization.yaml  # Image tags (CI updates) + backend resource limits patch
│   │       ├── hpa-backend.yaml    # HPA targets Rollout/backend: min 1, max 5
│   │       └── hpa-frontend.yaml   # HPA targets Deployment/frontend: min 1, max 3
│   │
│   ├── argocd/
│   │   └── application.yaml        # ArgoCD Application: watches k8s/overlays/prod/
│   │
│   └── secrets/
│       └── db-secret.yaml          # LOCAL DEV ONLY — placeholder, never real values
│
├── backend/
│   ├── app.js                      # createApp(db) factory: all routes + /metrics (prom-client)
│   ├── index.js                    # Creates MySQL connection, calls createApp(db), starts server
│   ├── package.json                # "test": "vitest run"
│   ├── package-lock.json
│   ├── Dockerfile                  # node:22-alpine, npm ci --omit=dev, non-root user
│   └── __tests__/
│       └── books.test.js           # 6 vitest tests, vi.fn() mock db, no real DB needed
│
├── client/
│   ├── src/
│   │   ├── App.js                  # Root React component
│   │   └── ...                     # React components for book list, add/edit/delete
│   ├── public/
│   ├── nginx.conf                  # nginx config: serve React build, temp paths in /tmp
│   ├── package.json
│   ├── package-lock.json
│   └── Dockerfile                  # Build stage: node:22-alpine npm build; Runner: nginx:1.27-alpine
│
└── .github/
    └── workflows/
        ├── ci-cd.yml               # Main pipeline: secret scan → SAST+tests → lint → build+scan+push → deploy
        └── terraform.yml           # Terraform pipeline: fmt check → validate → plan → apply
```

---

## 10. Implementation Guide

Complete steps to deploy this project from zero.

### Prerequisites

Install these tools locally:

```
aws CLI          >= 2.x       aws --version
terraform        >= 1.7       terraform version
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
./scripts/bootstrap-tf-state.sh us-west-1
```

Then fill in `main.tf` backend block with the printed values:

```hcl
backend "s3" {
  bucket         = "bookstore-terraform-state-<your-account-id>"
  key            = "prod/terraform.tfstate"
  region         = "us-west-1"
  dynamodb_table = "terraform-state-lock"
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

This creates: VPC, subnets, NAT gateway, EKS cluster, ECR repos, RDS, ACM certificate, GitHub OIDC role, Route53 private zone, and all cluster add-ons (cert-manager, ESO, ingress-nginx, ArgoCD, Prometheus, Argo Rollouts) via `modules/eks-addons/`.

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

(Alternatively, `eks_bootstrap.py` Phase 4 prompts you interactively if the secret does not exist.)

---

### Step 6 — Run eks_bootstrap.py

This script handles the remaining 8 phases that Terraform cannot do:

```bash
source config.env
DOMAIN=$DOMAIN python eks_bootstrap.py
```

**What it does (8 phases):**

| Phase | Action |
|-------|--------|
| 1 | Update kubeconfig (`aws eks update-kubeconfig`) |
| 2 | Apply ClusterIssuer (cert-manager CRDs exist from Terraform) |
| 3 | Create IRSA role + annotate `external-secrets-sa` service account |
| 4 | Validate/create AWS Secrets Manager secret |
| 5 | Apply ArgoCD Application manifest + patch ArgoCD secret key |
| 6 | Clear kubectl cache, force ESO resync |
| 7 | Wait for mysql-0, create DB schema + seed data |
| 8 | Print summary + Route53 NLB hostname reminder |

The script is **idempotent** — safe to re-run after failures.

---

### Step 7 — Trigger CI/CD Pipeline

Push a commit to `main` to trigger the pipeline:

```bash
git add .
git commit -m "feat: initial deployment"
git push origin main
```

In GitHub Actions, watch the pipeline. When it reaches the `deploy` stage, it pauses for approval. Go to **Actions → DevSecOps Pipeline → approve** to allow the deploy stage to update `k8s/overlays/prod/kustomization.yaml`.

After approval, the pipeline commits the new image SHA. ArgoCD detects this within 3 minutes and rolls out the new pods — backend via Argo Rollout canary, frontend via rolling update.

---

### Step 8 — Update Route53 DNS

After `eks_bootstrap.py` completes Phase 8, it prints the NLB hostname. Go to:

**AWS Console → Route 53 → Hosted zones → b17facebook.xyz**

Create (or update) two A records:

| Record | Type | Routing | Target |
|--------|------|---------|--------|
| `bookstore.b17facebook.xyz` | A | Alias | NLB hostname from Phase 8 |
| `api.bookstore.b17facebook.xyz` | A | Alias | Same NLB hostname |

DNS propagates within 60 seconds for Route53 alias records.

---

### Step 9 — Verify

```bash
# All pods running
kubectl get pods -n bookstore

# Expected:
# frontend-xxx   1/1   Running
# backend-xxx    1/1   Running   (canary rollout completes)
# mysql-0        1/1   Running

# TLS certificate issued
kubectl describe certificate bookstore-tls -n bookstore
# Status: True, Reason: Ready

# ArgoCD sync status
kubectl get application bookstore -n argocd
# STATUS: Synced, HEALTH: Healthy

# Argo Rollout status
kubectl argo rollouts get rollout backend -n bookstore
```

Open `https://bookstore.b17facebook.xyz` — the bookstore UI loads.  
Open `https://api.bookstore.b17facebook.xyz` — returns `"hello"` (JSON).  
Open `https://api.bookstore.b17facebook.xyz/metrics` — returns Prometheus metrics.

---

### Ongoing Operations

**Deploy a new version:** Push to `main` → approve deploy stage in GitHub Actions → ArgoCD auto-deploys (backend canary, frontend rolling).

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
kubectl rollout restart deployment/frontend -n bookstore
# Backend uses Argo Rollout — restart via:
kubectl argo rollouts restart backend -n bookstore
```

---

### Pending Items

| Item | Action |
|------|--------|
| Rotate SSH keys from `3-teir` / `github` files | Those files were once public — revoke the old keys immediately |
| Fill in S3 backend block in `main.tf` | See Step 1 above |
| Re-enable `deletion_protection = true` on RDS | Once infrastructure is stable |
| Point domain registrar NS records to Route53 | Required if `b17facebook.xyz` was registered outside Route53 |
