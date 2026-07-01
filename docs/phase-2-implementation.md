# Phase 2 — Implementation & Deployment Guide

> **Manual vs automated quick reference**
>
> | Step | Who does it | When |
> |---|---|---|
> | Clone repo, fill `config.env`, run `configure.py` | **Manual** (once) | Before first apply |
> | Bootstrap S3 backend (`bootstrap-tf-state.sh`) | **Manual** (once per account) | Before first apply |
> | Fill `versions.tf` backend block | **Manual** (once) | After bootstrap |
> | Everything in AWS: VPC, EKS, RDS, ECR, IAM, Secrets, EC2 monitoring stack | **Terraform** | `make apply` |
> | EKS add-ons: cert-manager, ESO, Nginx, ArgoCD, Argo Rollouts | **Terraform (Helm)** | `make apply` |
> | Monitoring: EC2 + Docker Compose + Dashboards + Alertmanager | **Terraform + user-data** | `make apply` |
> | IRSA role for ESO + ArgoCD Application | **`eks_bootstrap.py`** | After first apply |
> | Build + push images | **GitHub Actions CI** (or manual) | On push to main |
> | DNS NS records at registrar | **Manual** (once) | After first apply |
> | Configure Alertmanager receiver (Slack/email) | **Manual** (once, SSH) | After first apply |
>
> See [docs/observability.md](observability.md) for full monitoring detail.

---

## Prerequisites

| Tool | Version | Install |
|---|---|---|
| AWS CLI | >= 2.x | `brew install awscli` |
| Terraform | >= 1.7.0 | `brew install terraform` |
| kubectl | >= 1.28 | `brew install kubectl` |
| Helm | >= 3.x | `brew install helm` |
| Docker | any | Docker Desktop |
| git | any | pre-installed |

**AWS permissions required:** IAM, EKS, EC2, RDS, ECR, Route53, ACM, Secrets Manager, S3, DynamoDB.

```bash
# Verify AWS identity before starting
aws sts get-caller-identity
```

---

## Architecture Overview

```
Internet
  │
  ├── Route53 (public zone, health-check failover)
  │     └── CNAME → Nginx NLB (us-west-1)
  │
  └── CloudFlare / Registrar NS delegation to Route53
        │
  ┌─────▼──────────────────────────────────────────┐
  │  AWS us-west-1  VPC 170.20.0.0/16              │
  │                                                 │
  │  Public subnets  ──► Nginx NLB (LoadBalancer)  │
  │                         │                       │
  │  Private subnets        ▼                       │
  │    EKS node (t3.medium) ◄── ArgoCD GitOps       │
  │      ├── frontend pod (React)                   │
  │      ├── backend pod (Node.js) → RDS MySQL      │
  │      ├── cert-manager / ESO / Argo Rollouts     │
  │      ├── node-exporter  (systemd, not a pod)    │
  │      └── Fluent Bit     (systemd, not a pod)    │
  │                                                 │
  │  Public subnet                                  │
  │    monitoring EC2 (t3.small, EIP)               │
  │      ├── Prometheus  :9090                      │
  │      ├── Grafana     :3000                      │
  │      ├── Alertmanager :9093                     │
  │      ├── Loki        :3100                      │
  │      └── kube-state-metrics (reads EKS API)     │
  │                                                 │
  │  RDS private subnets                            │
  │    └── MySQL 8.0 (Multi-AZ, encrypted)          │
  └─────────────────────────────────────────────────┘
        │
  ECR (bookstore-frontend, bookstore-backend) ─► us-west-2 (Oregon) replica
  Secrets Manager (/bookstore/db-credentials)
```

---

## Step 1 — Clone and Configure

```bash
git clone https://github.com/YOUR_GITHUB_USERNAME/aws_three_tier_code.git
cd aws_three_tier_code
git checkout improvements
```

Copy and fill the config file:

```bash
cp config.env.example config.env
```

Edit `config.env`:
```bash
AWS_ACCOUNT_ID=<your-12-digit-account-id>
AWS_REGION=us-west-1
GITHUB_REPO=YOUR_GITHUB_USERNAME/aws_three_tier_code
DOMAIN=b17facebook.xyz       # your domain
```

Run the configure script (replaces ACCOUNT_ID placeholders in manifests):
```bash
python scripts/configure.py
```

---

## Step 2 — Bootstrap Terraform Remote State

Run **once** per AWS account before any `terraform` command:

```bash
./scripts/bootstrap-tf-state.sh us-west-1
```

The script prints the exact `backend "s3"` block to paste. Open `versions.tf` and fill in the two empty strings:

```hcl
backend "s3" {
  bucket         = "bookstore-terraform-state-<ACCOUNT_ID>"   # printed by script
  key            = "prod/terraform.tfstate"
  region         = "us-west-1"
  dynamodb_table = "terraform-state-lock"                     # printed by script
  encrypt        = true
}
```

Reinitialise with remote backend:
```bash
terraform init -migrate-state
```

---

## Step 3 — Set Terraform Variables

`terraform.tfvars` already has defaults. Verify:

```hcl
aws_region  = "us-west-1"
domain      = "b17facebook.xyz"    # must match your registered domain
github_repo = "YOUR_ORG/aws_three_tier_code"
```

Leave `primary_alb_dns` and `secondary_alb_dns` empty for the first apply.

---

## Step 4 — First Terraform Apply (Infrastructure)

```bash
terraform plan -out=tfplan
terraform apply tfplan
```

**What this creates:**
- VPC `170.20.0.0/16` with public + private subnets across 2 AZs
- EKS 1.31 cluster (`bookstore-eks`), 1 node (`t3.medium`), max 2
- RDS MySQL 8.0 (`db.t3.micro`, Multi-AZ, 25GB → auto-scales to 100GB)
- ECR repos (`bookstore-frontend`, `bookstore-backend`) + replication to `us-west-2` (Oregon)
- ACM TLS certificate for `*.b17facebook.xyz`
- Route53 public hosted zone for `b17facebook.xyz`
- Route53 private zone `bookstore.internal` → RDS CNAME
- All EKS add-ons via Helm: cert-manager, ESO, nginx-ingress, ArgoCD, Argo Rollouts
- **Monitoring EC2** (`t3.small`, EIP) with Docker Compose: Prometheus + Grafana + Alertmanager + Loki + kube-state-metrics — fully automated, no manual steps
- node-exporter + Fluent Bit baked into EKS node launch template (systemd, not pods)
- GitHub OIDC IAM role for CI

> **Tip:** Use `make apply` instead of `terraform apply` — it runs `init`, imports any pre-existing Secrets Manager secrets, then applies.

**Expected time:** 25–35 minutes (EKS + RDS + EC2 init).

Save outputs — needed in later steps:
```bash
terraform output            # print all
terraform output rds_endpoint
terraform output eks_cluster_name
terraform output route53_public_name_servers
terraform output rds_secret_arn

# Monitoring URLs (fully automated — just open these after apply)
terraform output grafana_url          # http://<EIP>:3000
terraform output prometheus_url       # http://<EIP>:9090
terraform output alertmanager_url     # http://<EIP>:9093
```

---

## Step 5 — Point Domain NS to Route53

After Step 4, Route53 assigned 4 name servers to your public zone. Go to your domain registrar (GoDaddy, Namecheap, etc.) and replace the default NS records with the 4 values from:

```bash
terraform output route53_public_name_servers
```

> NS propagation takes 5-60 minutes. ACM cert validation is DNS-based and will complete automatically once NS propagates.

---

## Step 6 — Configure kubeconfig

```bash
aws eks update-kubeconfig \
  --region us-west-1 \
  --name bookstore-eks

# Verify
kubectl get nodes
kubectl get pods -A
```

Expected: 1 node in `Ready` state, add-on pods running in `cert-manager`, `ingress-nginx`, `argocd`, `argo-rollouts` namespaces.

> **No monitoring namespace in EKS.** Prometheus, Grafana, Alertmanager, Loki, and kube-state-metrics all run on the monitoring EC2. Verify with `make monitoring-status`.

---

## Step 7 — Update RDS Endpoint in ConfigMap

**`DB_HOST` is now fully automated — no manual edit required.**

Terraform creates `/bookstore/db-credentials` in Secrets Manager with `DB_USERNAME`, `DB_PASSWORD`, and `DB_HOST` populated from the RDS instance endpoint. ESO pulls all three values and injects them into the `db-secret` Kubernetes Secret. The backend pod reads `DB_HOST` from the secret, not the ConfigMap.

Verify the secret was created after `terraform apply`:
```bash
aws secretsmanager get-secret-value \
  --secret-id /bookstore/db-credentials \
  --region us-west-1 \
  --query SecretString --output text | jq
```

---

## Step 8 — Apply ClusterIssuer (TLS)

**ClusterIssuer is now managed by ArgoCD — no manual `kubectl apply` needed.**

`k8s/base/cert-manager/cluster-issuer.yaml` is part of the Kustomize base. ArgoCD applies it automatically on sync. The prod overlay patches the ACME email to `kandukurisaikrishna778@gmail.com`.

Verify after ArgoCD syncs:
```bash
kubectl get clusterissuer letsencrypt-prod
```

---

## Step 9 — Create DB Secret in Secrets Manager

**Secret is now created automatically by Terraform — no manual AWS CLI step needed.**

`modules/rds/main.tf` creates `aws_secretsmanager_secret` at `/bookstore/db-credentials` with `DB_USERNAME`, `DB_PASSWORD` (from `random_password`), and `DB_HOST` (from `aws_db_instance.db.endpoint`) all populated in the same `terraform apply` that creates the RDS instance.

The `rds_secret_arn` Terraform output points to this secret. ESO reads from it every hour.

---

## Step 10 — Build and Push Docker Images

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

./scripts/build-and-push.sh \
  "${ACCOUNT_ID}" \
  "us-west-1" \
  "v1.0.0" \
  "https://api.b17facebook.xyz"
```

This builds and pushes:
- `<ACCOUNT_ID>.dkr.ecr.us-west-1.amazonaws.com/bookstore-frontend:v1.0.0`
- `<ACCOUNT_ID>.dkr.ecr.us-west-1.amazonaws.com/bookstore-backend:v1.0.0`

---

## Step 11 — Pin Image Tags in Kustomize Overlay

> **Note:** `k8s/overlays/prod/kustomization.yaml` ships with `000000000000` as the ECR registry placeholder — account ID intentionally not hardcoded in git. CI auto-fills from `secrets.AWS_ACCOUNT_ID` (GitHub Secret) on every push to `main`. For first manual deploy, run this once to prime the file with your real account ID.

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.us-west-1.amazonaws.com"

cd k8s/overlays/prod

kustomize edit set image \
  bookstore-frontend="${ECR_REGISTRY}/bookstore-frontend:v1.0.0"

kustomize edit set image \
  bookstore-backend="${ECR_REGISTRY}/bookstore-backend:v1.0.0"

cd ../../..
git add k8s/overlays/prod/kustomization.yaml
git commit -m "deploy: pin images to v1.0.0"
git push origin improvements
```

After CI's first successful deploy (Step 12 onwards), CI owns this step automatically — no more manual image pins needed.

---

## Step 12 — Deploy ArgoCD Application

Update the GitHub repo URL in `k8s/argocd/application.yaml`:
```yaml
source:
  repoURL: https://github.com/YOUR_GITHUB_USERNAME/aws_three_tier_code.git
  targetRevision: main     # change to 'improvements' for this branch
  path: k8s/overlays/prod
```

Apply:
```bash
kubectl apply -f k8s/argocd/application.yaml
```

ArgoCD will now:
1. Clone the repo
2. Run `kustomize build k8s/overlays/prod`
3. Apply all manifests to the `bookstore` namespace
4. Watch for changes every 3 minutes

Watch sync status:
```bash
# Get ArgoCD admin password
kubectl get secret -n argocd argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d

# Port-forward ArgoCD UI
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Open https://localhost:8080 — login: admin / <password above>
```

---

## Step 13 — Wire Route53 Records (Second Terraform Apply)

After ArgoCD deploys nginx-ingress (Step 12), the NLB is provisioned. Get its DNS:

```bash
kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

Add to `terraform.tfvars`:
```hcl
primary_alb_dns = "<nginx-nlb-hostname-from-above>"
```

Apply:
```bash
terraform apply
```

This creates the Route53 CNAME record: `b17facebook.xyz → <nginx NLB>` with health check and failover policy.

---

## Step 14 — Verify the Deployment

```bash
# All bookstore pods running
kubectl get pods -n bookstore

# Backend can reach RDS
kubectl logs -n bookstore -l app=backend --tail=20

# TLS cert issued
kubectl get certificate -n bookstore

# Ingress has address
kubectl get ingress -n bookstore

# Canary rollout status
kubectl argo rollouts get rollout backend -n bookstore --watch
```

Open the app:
- Frontend: `https://b17facebook.xyz`
- API: `https://api.b17facebook.xyz/books`

### Step 14b — Verify observability (EC2-based, no kubectl needed)

```bash
# Get monitoring URLs
terraform output grafana_url          # → http://<EIP>:3000
terraform output prometheus_url       # → http://<EIP>:9090
terraform output alertmanager_url     # → http://<EIP>:9093

# Get Grafana password
aws secretsmanager get-secret-value \
  --secret-id /bookstore/grafana-admin \
  --region us-west-1 \
  --query SecretString --output text

# Check all monitoring services healthy
make monitoring-status
# Expected: prometheus, kube-state-metrics, loki, alertmanager, grafana — all Up

# Prometheus scraping EKS nodes?
curl -s http://<EIP>:9090/api/v1/targets | jq \
  '.data.activeTargets[] | {job:.labels.job, health:.health}'
# Expected: node-exporter=up, kube-state-metrics=up, prometheus=up

# Alertmanager healthy?
curl -s http://<EIP>:9093/-/healthy
```

Open dashboards:
- **Grafana**: `http://<EIP>:3000` → Dashboards → Bookstore → Node Exporter Full
- **Prometheus**: `http://<EIP>:9090/targets` — all targets should be UP
- **Alertmanager**: `http://<EIP>:9093` — see active alerts

> For full observability docs: [docs/observability.md](observability.md)

---

## Step 15 — Test a Canary Rollout

Build and push a new image version, then update the overlay:

```bash
./scripts/build-and-push.sh "${ACCOUNT_ID}" us-west-1 v1.0.1 "https://api.b17facebook.xyz"

cd k8s/overlays/prod
kustomize edit set image bookstore-backend="${ECR_REGISTRY}/bookstore-backend:v1.0.1"
cd ../../..
git add k8s/overlays/prod/kustomization.yaml
git commit -m "deploy: backend v1.0.1"
git push
```

ArgoCD detects the change within 3 minutes and syncs. Argo Rollouts starts the canary:

```bash
# Watch canary progress
kubectl argo rollouts get rollout backend -n bookstore --watch

# Manual commands if needed:
kubectl argo rollouts promote backend -n bookstore   # skip pause
kubectl argo rollouts abort backend -n bookstore     # rollback to stable
```

Traffic progression: `10% → analysis check → 30s → 25% → 30s → 50% → analysis check → 60s → 100%`

If Prometheus detects >1% error rate during analysis, rollout aborts automatically.

---

## Architecture Components Reference

### Deployment Strategy (Backend)
- **Kind:** `argoproj.io/v1alpha1 Rollout` (not `Deployment`)
- **Strategy:** Canary — 10% → 25% → 50% → 100%
- **Gating:** AnalysisTemplate queries nginx 5xx rate every 30s; `failureLimit: 2`
- **Auto-rollback:** triggered if 2 consecutive analysis runs fail the `< 1% error rate` condition

### GitOps Flow
```
git push → GitHub Actions CI:
  1. Gitleaks (secret scan)
  2. SAST + tests [parallel with step 3]:
       - vitest (backend unit tests)
       - npm audit (backend high, frontend critical)
       - Semgrep (nodejs + owasp-top-ten + secrets)
  3. Validate [parallel with step 2]:
       - ESLint frontend (zero warnings)
       - kubeconform k8s manifests (v1.31.0)
  4. Docker build + Trivy scan (CRITICAL+HIGH = hard fail)
  5. Push to ECR (only after clean scan)
  6. kustomize edit set image (k8s/overlays/prod) [main branch only, requires approval]
  7. git commit + push (GITHUB_TOKEN, doesn't re-trigger CI)
     → ArgoCD polls, detects change, syncs cluster
```

### EKS Add-ons (via Terraform helm_release)

| Add-on | Namespace | Purpose |
|---|---|---|
| aws-ebs-csi-driver | kube-system | EBS PVC provisioning |
| cert-manager | cert-manager | TLS cert lifecycle |
| external-secrets | external-secrets | Secrets Manager → k8s Secret sync |
| ingress-nginx | ingress-nginx | L7 routing + NLB |
| argo-rollouts | argo-rollouts | Progressive delivery controller |
| argo-cd | argocd | GitOps sync controller |

> **No monitoring pods in EKS.** All observability runs on the monitoring EC2 (Docker Compose). See [docs/observability.md](observability.md).

### Monitoring Stack (EC2 Docker Compose — automated by Terraform)

| Service | Port | Purpose |
|---|---|---|
| Prometheus | 9090 | Metrics collection + alerting rule evaluation |
| Grafana | 3000 | Dashboards + log exploration |
| Alertmanager | 9093 | Alert routing → Slack / email / webhook |
| Loki | 3100 (VPC only) | Log aggregation from Fluent Bit |
| kube-state-metrics | 8080 (internal) | K8s cluster state metrics via EKS API |

**EKS node agents (systemd, not pods):**
- `node-exporter` v1.8.2 — hardware metrics on port 9100
- `Fluent Bit` — tails container logs, pushes to Loki

### Secrets Flow
```
terraform apply
    ↓
random_password resource generates 32-char password
    ↓
aws_db_instance.db created with that password
    ↓
aws_secretsmanager_secret_version writes to /bookstore/db-credentials:
    { DB_USERNAME, DB_PASSWORD, DB_HOST }
    ↓
ESO ClusterSecretStore (IRSA) reads /bookstore/db-credentials
    ↓
ESO creates k8s Secret "db-secret" in bookstore namespace
    ↓
Backend pod reads DB_USERNAME, DB_PASSWORD, DB_HOST via secretKeyRef
    ↓
Refreshed every 1h — no pod restart required
```

### Security Layers

| Layer | Mechanism |
|---|---|
| Network | VPC private subnets; Security Groups; NetworkPolicy default-deny |
| Pod | Non-root UID 1001; read-only rootfs; all capabilities dropped; seccomp RuntimeDefault |
| Secrets | No credentials in git; ESO + Secrets Manager |
| Images | ECR IMMUTABLE tags; Trivy scan in CI; scan-on-push in ECR |
| TLS | cert-manager + Let's Encrypt; enforced HTTPS redirect |
| IAM | IRSA (pod-level IAM, not node-level); OIDC for CI |

### Multi-Region Failover

**Normal:** Route53 → `b17facebook.xyz` CNAME → nginx NLB (us-west-1) ✅ PRIMARY
**Failover:** Health check fails 3 consecutive times → Route53 routes to `secondary_alb_dns` (us-west-2 Oregon)

**DR steps when primary fails:**
1. Route53 auto-switches to secondary (if `secondary_alb_dns` is set)
2. Restore RDS from replicated backup in us-west-2
3. Deploy EKS in us-west-2 (same manifests, same ArgoCD app)
4. Update `/bookstore/db-credentials` secret in us-west-2 with secondary RDS endpoint as `DB_HOST`
5. Set `secondary_alb_dns` in `terraform.tfvars` → `terraform apply`

---

## Troubleshooting

| Symptom | Check |
|---|---|
| Backend pod `CrashLoopBackOff` | `kubectl logs -n bookstore -l app=backend` — likely `DB_HOST` not set or RDS unreachable |
| TLS cert pending | `kubectl describe certificate -n bookstore` — verify ClusterIssuer email and NS delegation |
| ArgoCD app `OutOfSync` | Check if git repo URL in `application.yaml` matches actual repo |
| ESO secret not created | `kubectl describe externalsecret -n bookstore db-secret` — IRSA role or secret path wrong |
| Canary stuck at 10% | `kubectl argo rollouts get rollout backend -n bookstore` — check analysis failure reason |
| Nginx 504 | Backend not ready — check readiness probe and RDS connectivity |
| Route53 not resolving | NS records at registrar not updated yet — allow 60 min propagation |
