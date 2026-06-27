# Phase 2 — Architecture Deep Dive

> Bookstore app: React frontend + Node.js/Express backend + MySQL.  
> Deployed on AWS EKS with full GitOps, progressive delivery, observability, and security hardening.

---

## High-Level Architecture

```
                         ┌─────────────────────────────────────────────────────────┐
                         │                   AWS us-west-1                          │
  User Browser           │                                                           │
       │                 │  ┌──────────────┐     ┌───────────────────────────────┐  │
       │  HTTPS          │  │  CloudFront  │────▶│  Route53 (public zone)        │  │
       └────────────────▶│  │  (optional)  │     │  Active/Passive failover       │  │
                         │  └──────────────┘     └───────────────────────────────┘  │
                         │         │                         │                       │
                         │         ▼                         ▼                       │
                         │  ┌──────────────────────────────────────────────────────┐│
                         │  │              VPC  170.20.0.0/16                       ││
                         │  │                                                        ││
                         │  │  Public Subnets (.1, .2)       Private Subnets (.3–.8)││
                         │  │  ┌────────────┐                                        ││
                         │  │  │ NAT GW     │──────────────────────────────────────▶││
                         │  │  │ (us-west-1a│               ┌──────────────────┐    ││
                         │  │  └────────────┘               │  EKS Node Group  │    ││
                         │  │  ┌────────────┐               │  (t3.medium)     │    ││
                         │  │  │ Internet   │               │                  │    ││
                         │  │  │ Gateway    │               │  ┌─────────────┐ │    ││
                         │  │  └────────────┘               │  │ nginx-ingress│ │    ││
                         │  │                               │  └──────┬──────┘ │    ││
                         │  │                               │         │        │    ││
                         │  │                               │  ┌──────▼──────┐ │    ││
                         │  │                               │  │  frontend   │ │    ││
                         │  │                               │  │  (Nginx)    │ │    ││
                         │  │                               │  └─────────────┘ │    ││
                         │  │                               │  ┌─────────────┐ │    ││
                         │  │                               │  │  backend    │ │    ││
                         │  │                               │  │  (Node.js)  │ │    ││
                         │  │                               │  └──────┬──────┘ │    ││
                         │  │                               └─────────│────────┘    ││
                         │  │                                         │              ││
                         │  │                               ┌─────────▼────────┐    ││
                         │  │                               │  RDS MySQL 8.0   │    ││
                         │  │                               │  (Multi-AZ)      │    ││
                         │  │                               │  Subnets .7, .8  │    ││
                         │  │                               └──────────────────┘    ││
                         │  └──────────────────────────────────────────────────────┘│
                         │                                                           │
                         │  ┌────────────┐  ┌────────────┐  ┌──────────────────┐   │
                         │  │ ECR        │  │ Secrets    │  │  CloudTrail      │   │
                         │  │ (2 repos)  │  │ Manager    │  │  GuardDuty       │   │
                         │  └────────────┘  └────────────┘  │  VPC Flow Logs   │   │
                         │                                   └──────────────────┘   │
                         └─────────────────────────────────────────────────────────┘

  GitHub Actions CI ──────────────────────────────────────────────────────────────▶ ECR
  ArgoCD (in-cluster) ◀──────── git repo (k8s/overlays/prod/kustomization.yaml)
```

---

## Layer 1 — Network (VPC)

### CIDR Layout

| Subnet | CIDR | AZ | Role |
|---|---|---|---|
| public-1 | 170.20.1.0/24 | us-west-1a | NAT GW, Load Balancer |
| public-2 | 170.20.2.0/24 | us-west-1c | Load Balancer (HA) |
| private-1 | 170.20.3.0/24 | us-west-1a | EKS nodes |
| private-2 | 170.20.4.0/24 | us-west-1c | EKS nodes |
| private-3 | 170.20.5.0/24 | us-west-1a | EKS nodes (overflow) |
| private-4 | 170.20.6.0/24 | us-west-1c | EKS nodes (overflow) |
| private-5 | 170.20.7.0/24 | us-west-1a | RDS primary |
| private-6 | 170.20.8.0/24 | us-west-1c | RDS standby (Multi-AZ) |

### Egress Path

Pods → private subnet → single NAT Gateway (us-west-1a) → Internet Gateway → internet.

> Single NAT = cost-optimised for demo. AZ failure loses outbound egress for private subnets. For production HA: add one NAT per AZ (~$32/mo each).

### VPC Flow Logs

All traffic (ACCEPT + REJECT) logged to CloudWatch `/aws/vpc/flowlogs/bookstore` with 90-day retention. IAM role scoped to `logs:PutLogEvents` only. Primary use cases: post-incident forensics, GuardDuty data enrichment, verifying NetworkPolicy enforcement.

---

## Layer 2 — Compute (EKS)

### Cluster

| Property | Value |
|---|---|
| Name | `bookstore-eks` |
| Version | 1.31 (EOL: ~2026-11 — see upgrade runbook) |
| Control plane logs | api, audit, authenticator, controllerManager, scheduler |
| Public endpoint | Enabled (restrict `public_access_cidrs` to admin IPs before go-live) |
| Private endpoint | Enabled — in-cluster components use private API |
| OIDC provider | Auto-created — required for IRSA (IAM Roles for Service Accounts) |

### Node Group

| Property | Value |
|---|---|
| Instance | t3.medium (2 vCPU, 4 GB RAM) |
| Min / Desired / Max | 1 / 1 / 2 |
| AMI | AL2_x86_64 |
| Subnets | private-1 through private-4 |
| Max unavailable on update | 1 |

### IAM Roles

```
aws_iam_role.cluster  ──▶  AmazonEKSClusterPolicy
                       ──▶  AmazonEKSVPCResourceController

aws_iam_role.node_group  ──▶  AmazonEKSWorkerNodePolicy
                          ──▶  AmazonEKS_CNI_Policy
                          ──▶  AmazonEC2ContainerRegistryReadOnly
```

All roles use least-privilege managed policies. No inline wildcard permissions.

---

## Layer 3 — Data (RDS + Secrets Manager)

### RDS MySQL

| Property | Value |
|---|---|
| Engine | MySQL 8.0 |
| Instance | db.t3.micro |
| Storage | 25 GB gp2, autoscales to 100 GB |
| Multi-AZ | Yes — automatic standby in us-west-1c |
| Encryption | AES-256 via AWS-managed KMS key |
| Backups | 7-day retention, 03:00–04:00 UTC window |
| Performance Insights | Enabled, 7-day retention (free tier) |
| Enhanced Monitoring | 60-second interval (IAM role: AmazonRDSEnhancedMonitoringRole) |
| CloudWatch Logs | error, general, slowquery |
| Deletion protection | `true` — must disable manually before destroy |
| Final snapshot | Created on destroy — `<db-identifier>-final-snapshot` |
| Publicly accessible | `false` — only accessible within VPC |

### Credential Flow

```
Terraform apply
  → random_password (32 chars, special chars)
  → aws_secretsmanager_secret (/bookstore/db-credentials)
       │  replica → us-east-1  (for DR)
       └─ rotation ready (set rotation_lambda_arn to activate)

In-cluster:
  ESO ServiceAccount (IRSA)
  → assumes IAM role with secretsmanager:GetSecretValue on /bookstore/db-credentials
  → ExternalSecret (refreshInterval: 1h)
  → Kubernetes Secret "db-secret"
  → backend Pod env vars: DB_HOST, DB_USERNAME, DB_PASSWORD
```

Credentials never touch git. ESO pulls from AWS. Rotation activates within 1h without pod restart.

### RDS Backup Replication (DR)

`aws_db_instance_automated_backups_replication` replicates automated backups to us-east-1. In a DR event: restore from backup in us-east-1, promote to standalone, update `DB_HOST` in Secrets Manager replica, ESO picks up within 1h.

---

## Layer 4 — Container Registry (ECR)

Two repositories: `bookstore-backend`, `bookstore-frontend`.

| Feature | Setting |
|---|---|
| Image mutability | IMMUTABLE — tags cannot be overwritten |
| Lifecycle policy | Keep last 10 images per repo (configurable via `image_retention_count`) |
| Encryption | AES-256 (AWS-managed) |
| Cross-region replication | All `bookstore-*` repos replicated to us-east-1 (for DR secondary cluster) |

Image tag format: `<ACCOUNT>.dkr.ecr.us-west-1.amazonaws.com/bookstore-<app>:<git-sha-8>`. Never `latest` in prod.

---

## Layer 5 — Kubernetes Workloads

### Namespace Layout

| Namespace | Contents |
|---|---|
| `bookstore` | frontend Deployment, backend Rollout, ESO ExternalSecret, db-secret, configmap, ingress, quota, PDB, NetworkPolicy |
| `monitoring` | Prometheus, Grafana, Loki, Alertmanager, ServiceMonitor |
| `argocd` | ArgoCD server, repo-server, application-controller |
| `ingress-nginx` | nginx-ingress controller, NLB service |
| `cert-manager` | cert-manager controller, ClusterIssuer, Certificate |
| `argo-rollouts` | Argo Rollouts controller |
| `external-secrets` | ESO controller, ClusterSecretStore |

### Frontend (Deployment)

- Image: `bookstore-frontend:<sha>` (Nginx 1.27, multi-stage build: React → static files)
- Replicas: 2 (base), HPA 2–3 in prod overlay
- Security: `runAsNonRoot`, `runAsUser: 101`, `readOnlyRootFilesystem: true`, all caps dropped, seccomp `RuntimeDefault`
- Writable volumes: `/tmp`, `/var/cache/nginx`, `/var/run` (emptyDir)
- Probe: `GET /health :8080`
- Port 8080 (non-root Nginx)

### Backend (Argo Rollout)

- Image: `bookstore-backend:<sha>` (Node.js 18 Alpine, production deps only)
- Replicas: 1 base, HPA 1–5 in prod overlay
- Security: `runAsNonRoot`, `runAsUser: 1001`, `readOnlyRootFilesystem: true`, all caps dropped, seccomp `RuntimeDefault`
- Writable volumes: `/tmp` (emptyDir)
- Probe: `GET /health :3000 → 200 { status: "ok" }`
- Exposes `/metrics` (prom-client) for Prometheus scraping

### Dev MySQL (StatefulSet — dev only)

- Image: `mysql:8.0.39` (pinned patch version)
- Security: `allowPrivilegeEscalation: false`, caps drop ALL + re-add CHOWN/SETUID/SETGID/DAC_OVERRIDE (init requirement)
- Pod-level `fsGroup: 999` (mysql user owns data volume)
- PVC: 10 Gi gp3 via `aws-ebs-csi-driver`
- Probes: `mysqladmin ping` (readiness 20s delay, liveness 60s delay)

> In prod, `DB_HOST` points to RDS. The MySQL StatefulSet is retained for local dev/CI only.

### Kustomize Overlays

```
k8s/
├── base/              # shared manifests (no image tags, no replicas)
│   ├── backend/       # Rollout, Service
│   ├── frontend/      # Deployment, Service
│   ├── database/      # MySQL StatefulSet (dev)
│   ├── ingress/       # Ingress (domain, TLS annotation)
│   ├── configmaps/    # backend-config (DB_PORT, DB_NAME, APP_PORT)
│   ├── secrets/       # ExternalSecret (pulls from SM)
│   ├── network-policy/# deny-all + allow-specific NetworkPolicy
│   ├── pdb/           # backend-pdb + frontend-pdb (minAvailable: 1)
│   ├── quota.yaml     # ResourceQuota (bookstore namespace)
│   ├── monitoring/    # ServiceMonitor, AnalysisTemplate, PrometheusRule
│   └── cert-manager/  # ClusterIssuer
│
├── overlays/
│   ├── dev/           # dev kustomization (base only, no image pins)
│   └── prod/          # image pins (set by CI), HPA manifests
```

CI commits new image SHA to `k8s/overlays/prod/kustomization.yaml`. ArgoCD polls every 3 minutes and reconciles. No `kubectl` in CI for deploy — pure GitOps.

---

## Layer 6 — Ingress & TLS

```
Internet
  │ HTTPS :443
  ▼
NLB (AWS Network Load Balancer)   ← provisioned by nginx-ingress controller
  │
  ▼
nginx-ingress controller pod
  │ routes by host header
  ├── bookstore.b17facebook.xyz → frontend:8080
  └── bookstore.b17facebook.xyz/api/* → backend:3000
  │
  ▼
cert-manager + Let's Encrypt (ACME HTTP-01)
  → Certificate stored as Kubernetes Secret
  → Auto-renewed 30 days before expiry
```

ClusterIssuer: `letsencrypt-prod`. ACME email: `kandukurisaikrishna778@gmail.com`. Solver: HTTP-01 via nginx-ingress. TLS termination at nginx. Backend sees HTTP internally.

CloudFront (optional, `enable_cloudfront = true`):
- Static assets (`/static/*`) cached at edge, TTL 7 days
- Dynamic API requests: TTL 0 (pass-through)
- ACM cert provisioned in us-east-1 (CloudFront requirement, uses `aws.secondary` provider alias)
- Route53 CNAME flips from NLB hostname to CloudFront domain when enabled

---

## Layer 7 — GitOps (ArgoCD)

```
GitHub repo (improvements/main branch)
      │
      │ polls every 3 min
      ▼
ArgoCD Application (bookstore)
      │ reconciles k8s/overlays/prod/
      ├── selfHeal: true   → reverts manual kubectl changes
      ├── prune: true      → deletes resources removed from git
      └── automated sync   → no manual approval needed after image tag commit
```

ArgoCD itself is deployed via `helm_release` in `modules/eks-addons/main.tf`. Application manifest lives at `k8s/argocd/application.yaml`.

**Deploy flow:**

```
1. Developer pushes to `improvements`
2. GitHub Actions: secret-scan → sast → validate → build-and-push (only on push, not PR)
3. CI commits updated image SHA to k8s/overlays/prod/kustomization.yaml
4. ArgoCD detects change within 3 min → applies → triggers Argo Rollout
5. Rollout: 10% canary → AnalysisTemplate (error rate check) → 25% → 50% → 100%
6. On analysis failure: auto-abort, previous stable image promoted back
```

For `main` branch: `deploy` job requires manual approval via GitHub `production` environment gate (timeout: 30 min).

---

## Layer 8 — Progressive Delivery (Argo Rollouts)

Backend uses `Rollout` (not `Deployment`) with canary strategy:

```
New image deployed
  ├── Step 1: setWeight 10%   (1 in 10 requests hit canary pod)
  ├── Step 2: analysis (error-rate AnalysisTemplate)
  │     Query: sum(5xx rate) / sum(all rate) [2m]
  │     Threshold: < 0.05 (5% error rate)
  │     Guard: or vector(0) / or vector(1)  ← prevents div-by-zero on zero traffic
  ├── Step 3: pause 30s
  ├── Step 4: setWeight 25%
  ├── Step 5: pause 30s
  ├── Step 6: setWeight 50%
  ├── Step 7: analysis (repeat)
  └── Step 8: pause 60s → promote to 100%

On failure: automatic abort → stable version at 100%
Manual abort: kubectl argo rollouts abort backend -n bookstore
```

Traffic splitting uses the nginx-ingress `canary-weight` annotation. Prometheus provides error rate data.

---

## Layer 9 — Observability

### Metrics Stack (kube-prometheus-stack)

```
backend /metrics (prom-client)
    ↑ scraped by
Prometheus (ServiceMonitor CRD auto-discovers)
    → stores in local TSDB (gp3 PVC)
    → evaluates PrometheusRules (alerting)
    → feeds AnalysisTemplate (canary decisions)
    ↓ queried by
Grafana
    → dashboards: request rate, latency (p50/p95), error rate, pod CPU/mem
    → admin password: /bookstore/grafana-admin (Secrets Manager)
    → Loki datasource auto-provisioned (additionalDataSources)
```

Grafana admin password is `random_password` (24 chars, no specials), stored in `/bookstore/grafana-admin` SM secret. Retrieve: `aws secretsmanager get-secret-value --secret-id /bookstore/grafana-admin --query SecretString --output text`.

### Log Stack (Loki)

Loki installed via `loki-stack` helm release. Collects pod logs via promtail DaemonSet. Grafana datasource pre-configured — no manual setup. Query logs alongside metrics in same Grafana panel using LogQL.

### Custom Metrics (backend)

```javascript
// prom-client counters/histograms in app.js
http_requests_total{method, route, status}
http_request_duration_seconds{method, route, status}
```

PrometheusRule fires `HighErrorRate` alert when 5xx rate > 1% for 2 minutes.

### RDS Metrics

Performance Insights (7-day free tier) + Enhanced Monitoring (60s interval) + CloudWatch Logs (error/general/slowquery). View in RDS console or query via CloudWatch Metrics.

---

## Layer 10 — Security

### Kubernetes Security

| Control | Applied To | Detail |
|---|---|---|
| `runAsNonRoot: true` | backend (UID 1001), frontend (UID 101) | No root processes |
| `readOnlyRootFilesystem: true` | backend, frontend | Container fs immutable |
| `allowPrivilegeEscalation: false` | all containers | No suid/sgid escalation |
| `capabilities.drop: [ALL]` | backend, frontend | Zero Linux capabilities |
| `seccompProfile: RuntimeDefault` | backend, frontend | Default syscall filter |
| `hostNetwork/hostPID/hostIPC` | not set | Defaults false — isolated |
| NetworkPolicy | bookstore namespace | Deny all by default, allow-listed ingress/egress |
| PodDisruptionBudget | backend, frontend | `minAvailable: 1` — drain-safe |
| ResourceQuota | bookstore namespace | CPU 2req/4lim, Memory 2Gi/4Gi, pods: 20 |

### AWS Security

| Control | Resource | Detail |
|---|---|---|
| GuardDuty | `aws_guardduty_detector` | EKS audit + S3 + malware scan |
| CloudTrail | `aws_cloudtrail` | Multi-region, log-file validation, encrypted S3 |
| VPC Flow Logs | `aws_flow_log` | ALL traffic → CloudWatch, 90d retention |
| SM recovery window | `/bookstore/db-credentials` | 7-day grace period before delete |
| RDS encryption | `storage_encrypted = true` | AWS-managed KMS |
| RDS deletion protection | `deletion_protection = true` | Manual disable required |
| ECR immutable tags | Both repos | Tags cannot be overwritten |
| IAM least privilege | All roles | Managed policies + scoped inline policies |
| OIDC trust restriction | GitHub Actions role | Trust only `main` + `improvements` branches |
| EKS API CIDR | `public_access_cidrs` | Variable — set to admin IPs before go-live |
| S3 public access block | CloudTrail bucket | Block all public access |

### CI/CD Security

| Control | Detail |
|---|---|
| No static AWS keys | OIDC only — `role-to-assume` via `aws-actions/configure-aws-credentials` |
| Gitleaks | Every push/PR — fail immediately on detected secrets |
| Semgrep SAST | Node.js + OWASP Top-10 rules |
| Trivy container scan | CRITICAL + HIGH = hard fail — image never pushed dirty |
| Trivy IaC scan | Terraform `.tf` files scanned before plan |
| npm audit | backend: `--audit-level=high`, frontend: `--audit-level=critical` |
| `GITHUB_TOKEN` scope | Minimal per-job: `contents: read`, `id-token: write`, `security-events: write` |
| SARIF upload | Trivy findings visible in GitHub Security tab |
| Action pinning | `trivy-action@master` → `@v0.28.0` |
| CODEOWNERS | All paths require `@KANDUKURIsaikrishna` approval |

---

## Layer 11 — CI/CD Pipeline

### GitHub Actions Workflow

```
push to main/improvements
│
├── secret-scan (Gitleaks — full history)
│
├── sast (parallel with validate)
│   ├── npm ci + npm test (backend vitest)
│   ├── npm audit (backend high, frontend critical)
│   └── Semgrep (nodejs + owasp-top-ten + secrets)
│
├── validate (parallel with sast)
│   ├── ESLint frontend (zero warnings)
│   └── kubeconform k8s manifests (v1.31.0)
│
└── build-and-push (only on push, not PR)
    ├── aws-actions OIDC login
    ├── ECR login
    ├── Docker buildx build (--load, no push yet)
    ├── Trivy scan (CRITICAL+HIGH = fail, ignore-unfixed)
    ├── SARIF upload to GitHub Security tab
    └── docker push (only after clean scan)

then → deploy (only main branch, requires production env approval)
    ├── kustomize edit set image (prod overlay)
    └── git commit + push (GITHUB_TOKEN, no re-trigger loop)
```

Terraform workflow (separate, on `.tf` file changes):

```
push/PR to main (*.tf changes)
├── aws-actions OIDC login
├── Trivy IaC scan (CRITICAL+HIGH = fail)
├── terraform fmt -check
├── terraform init
├── terraform validate
├── terraform plan (saved to tfplan)
├── comment plan on PR
└── terraform apply (only on push to main, uses tfplan)
```

Drift detection (daily cron 06:00 UTC):

```
terraform plan -detailed-exitcode
  exit 0 → no drift
  exit 2 → drift detected → job fails → GitHub alert
  exit 1 → plan error → job fails → check auth/state
```

---

## Layer 12 — Disaster Recovery

### RTO / RPO Targets

| Scenario | RPO | RTO |
|---|---|---|
| Pod crash | 0 (stateless) | ~30s (readiness probe) |
| Node failure | 0 (pods reschedule) | ~2 min (node replacement) |
| AZ failure (single NAT) | 0 | ~5 min (manual NAT re-route) |
| RDS AZ failure | 0 (Multi-AZ auto-failover) | ~60–120s (DNS flip) |
| Region failure | ~1h (SM sync + ESO poll) | ~1 day (manual secondary EKS setup) |

### Region Failover Runbook (Manual)

1. Restore RDS backup in us-east-1 (automated backup replication configured)
2. Update `/bookstore/db-credentials` replica in us-east-1 with new `DB_HOST`
3. Deploy secondary EKS cluster in us-east-1 (Terraform secondary-region module — Phase 3)
4. ECR images already replicated to us-east-1 registry
5. Route53 health check detects primary failure → SECONDARY record activates
6. ESO in secondary cluster reads SM replica → credentials available

### Route53 Failover

```
aws_route53_health_check.primary
  → checks HTTPS :443 / on var.domain (failure_threshold: 3, interval: 30s)

aws_route53_record.primary  (set_identifier: "primary", FAILOVER PRIMARY)
  → CNAME to primary NLB DNS
aws_route53_record.secondary  (set_identifier: "secondary", FAILOVER SECONDARY)
  → CNAME to secondary NLB DNS (when var.secondary_alb_dns != "")
```

Primary health check failure triggers automatic DNS failover to secondary record within ~90 seconds (3 × 30s interval).

---

## Key Design Decisions

| Decision | Chosen | Alternative Considered | Why |
|---|---|---|---|
| State backend | Local (S3 ready) | S3 + DynamoDB | S3 backend is configured in `versions.tf` but bucket not bootstrapped — run `./scripts/bootstrap-tf-state.sh` |
| Node size | t3.medium | t3.small | Prometheus + all add-ons require ~3.5 GB RAM. t3.small (2 GB) OOMs |
| NAT gateway | Single (1a) | Per-AZ | Cost: $32/mo each. Single sufficient for demo. Documented HA upgrade path |
| DB | RDS (managed) | In-cluster MySQL | Managed HA, backups, metrics. No PV/PVC risk |
| GitOps | ArgoCD | Flux | ArgoCD has richer UI for demo, same capabilities |
| Secret management | ESO + SM | Sealed Secrets | SM = centralized rotation, audit, cross-region. ESO auto-syncs |
| Image build | Docker Buildx (GHA cache) | Kaniko | Buildx + gha cache = fast, well-supported |
| Progressive delivery | Argo Rollouts canary | Flagger | Rollouts = same API group as ArgoCD ecosystem |
| Observability | kube-prometheus-stack | manual Prometheus | Helm chart bundles CRDs, default dashboards, alertmanager |
| TLS | cert-manager + LE | AWS ACM (for EKS) | cert-manager works in-cluster, LE = free, ACM needs NLB annotation complexity |

---

## Component Versions (Phase 2)

| Component | Version | Notes |
|---|---|---|
| Terraform | 1.10.0 | Locked in `versions.tf` |
| EKS | 1.31 | EOL ~2026-11 |
| Kubernetes | 1.31 | |
| Node.js | 18 (Alpine) | LTS |
| React | 18 | CRA |
| MySQL | 8.0.39 | Pinned in StatefulSet |
| Nginx (frontend) | 1.27-alpine | |
| cert-manager | v1.16.2 | |
| External Secrets Operator | v0.10.7 | |
| Argo Rollouts | v1.7.2 | |
| ArgoCD | via helm chart | |
| kube-prometheus-stack | via helm chart | Prometheus + Grafana + Alertmanager |
| loki-stack | via helm chart | Loki + Promtail |
| aws-ebs-csi-driver | via EKS managed addon | gp3 StorageClass |
| ingress-nginx | via helm chart | NLB service type |

---

## File Map (Quick Reference)

```
.
# ── Root module (one concern per file) ──────────────────────────────────────
├── providers.tf             # aws (primary + secondary alias), helm providers
├── versions.tf              # required_providers versions, S3 backend config
├── variables.tf             # all input variables (domain, github_repo, enable_cloudfront, …)
├── locals.tf                # VPC CIDR + subnet list — shared across multiple modules
├── data.tf                  # data "aws_caller_identity" — consumed by IAM + CloudTrail
├── main.tf                  # module calls only (network, security, acm, rds, ecr, eks, eks-addons, route53)
├── outputs.tf               # VPC ID, ECR URLs, EKS endpoint, Route53 zone, CloudFront domain, …
├── iam.tf                   # GitHub OIDC role + ECR push policy (root-level IAM)
│
# ── Root-level concern files (NOT in modules — see rationale below) ──────────
├── cloudfront.tf            # ACM cert (us-east-1) + CloudFront distribution
│                            #   → uses provider = aws.secondary (alias); cannot cleanly
│                            #     move into child module without providers{} boilerplate
├── dr.tf                    # RDS automated-backup cross-region replication
│                            #   → uses provider = aws.secondary (same reason)
├── cloudtrail.tf            # S3 bucket + policy + CloudTrail trail
│                            #   → account-level audit control; no single module owns it
├── guardduty.tf             # GuardDuty detector
│                            #   → account-level threat detection; same reason
│
# ── Child modules ────────────────────────────────────────────────────────────
├── modules/
│   ├── network/             # VPC, subnets, IGW, NAT GW, route tables, VPC flow logs
│   ├── security/            # Security groups (EKS nodes, RDS, Nginx)
│   ├── acm/                 # ACM cert for us-west-1 (EKS ingress TLS)
│   ├── rds/                 # RDS MySQL, Secrets Manager secret + rotation
│   ├── ecr/                 # ECR repos, lifecycle policies, cross-region replication config
│   ├── eks/
│   │   ├── main.tf          # EKS cluster, OIDC provider, managed node group
│   │   └── iam.tf           # Cluster IAM role + node group IAM role + policy attachments
│   ├── eks-addons/
│   │   ├── main.tf          # required_providers block only
│   │   ├── ebs-csi.tf       # EBS CSI driver addon
│   │   ├── cert-manager.tf  # cert-manager Helm release
│   │   ├── external-secrets.tf  # ESO Helm release
│   │   ├── ingress.tf       # ingress-nginx Helm release
│   │   ├── observability.tf # kube-prometheus-stack + Loki Helm releases
│   │   ├── gitops.tf        # Argo Rollouts + ArgoCD Helm releases
│   │   └── grafana-secret.tf    # Grafana admin SM secret (recovery_window=7d)
│   └── route53/             # Public zone, health check, active/passive failover records
│
├── k8s/
│   ├── base/                # Kustomize base manifests
│   │   ├── backend/         # Rollout + Service
│   │   ├── frontend/        # Deployment + Service
│   │   ├── database/        # MySQL StatefulSet (dev)
│   │   ├── ingress/         # Ingress (TLS, host rules)
│   │   ├── configmaps/      # backend-config
│   │   ├── secrets/         # ExternalSecret
│   │   ├── cert-manager/    # ClusterIssuer
│   │   ├── network-policy/  # bookstore namespace policies
│   │   ├── pdb/             # PodDisruptionBudgets
│   │   ├── monitoring/      # ServiceMonitor, AnalysisTemplate, PrometheusRule
│   │   ├── storageclass/    # gp3 StorageClass
│   │   ├── quota.yaml       # ResourceQuota
│   │   └── kustomization.yaml
│   └── overlays/
│       ├── dev/             # dev kustomization
│       └── prod/            # image pins (updated by CI), HPA
│
├── .github/
│   ├── workflows/
│   │   ├── ci-cd.yml        # DevSecOps pipeline
│   │   ├── terraform.yml    # Terraform plan + apply
│   │   └── terraform-drift.yml  # Daily drift detection
│   └── CODEOWNERS           # Review enforcement
│
├── backend/                 # Node.js/Express API
│   ├── app.js               # Routes: /health, /books CRUD, /metrics
│   ├── index.js             # DB connection + server start
│   └── __tests__/           # vitest unit tests
│
├── client/                  # React frontend (CRA)
│   └── src/                 # Books CRUD UI
│
└── docs/
    ├── phase-2-architecture.md      # this file
    ├── phase-2-improvements.md      # what changed from phase 1
    ├── phase-2-future-improvements.md  # backlog + implementation notes
    └── eks-upgrade-runbook.md       # EKS version upgrade procedure
```

---

## Terraform Module Design Rationale

### Why are some `.tf` files at root instead of in `modules/`?

Three distinct reasons:

#### 1. Provider alias constraint (`cloudfront.tf`, `dr.tf`)

Both files contain resources that target a secondary AWS region via `provider = aws.secondary`:

- `cloudfront.tf` — ACM certificate in `us-east-1` (CloudFront requirement) + CloudFront distribution
- `dr.tf` — RDS automated-backup cross-region replication to secondary region

Terraform does **not** transparently pass provider aliases into child modules. To move these into a module you would need:
1. `providers = { aws.secondary = aws.secondary }` block in every module call
2. Explicit alias declaration inside the child module's `required_providers`

For 8–84 line files this is pure boilerplate with no benefit. HashiCorp's own guidance: keep resources with provider aliases at root when they don't justify a dedicated module.

#### 2. Account-level cross-cutting concerns (`cloudtrail.tf`, `guardduty.tf`)

- **CloudTrail** — audits the entire AWS account (S3 bucket + bucket policy + trail). Not owned by network, EKS, or RDS — it spans all of them.
- **GuardDuty** — account-level threat detection; one detector per account.

No child module "owns" account-level resources. Standard Terraform community pattern: account-scope security controls live at root in dedicated files.

#### 3. Shared data sources and locals (`data.tf`, `locals.tf`)

- `data "aws_caller_identity"` is consumed by both the root IAM module (GitHub OIDC trust) and `cloudtrail.tf` (S3 bucket policy). Data sources don't cross module boundaries — if placed inside one module, other modules can't access them.
- `locals.tf` defines VPC CIDRs and all subnet CIDR/AZ pairs. These are passed as arguments to `module.network`, `module.security`, and `module.eks`. Must be at root to be available everywhere.

### Rule of thumb

| Put at root | Put in module |
|---|---|
| Uses `provider = aws.secondary` (alias) | Logically cohesive group of resources (VPC, EKS, RDS) |
| Account-wide service (CloudTrail, GuardDuty, Config) | Can be reused or independently versioned |
| Data source consumed by 2+ modules | Single-concern infra with clear ownership |
| Locals shared across 2+ module calls | — |
