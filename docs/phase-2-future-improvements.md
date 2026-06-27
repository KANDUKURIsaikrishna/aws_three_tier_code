# Phase 2 — Future Improvements

> These are targeted, incremental improvements to the existing Phase 2 architecture.
> Each item is self-contained — implement in any order based on priority.
> Phase 3 (second region EKS, full active-active) is tracked separately.

---

## 1. Fix Division-by-Zero in AnalysisTemplate

**File:** `k8s/base/monitoring/analysis-template.yaml`

**Problem:** When ingress traffic is zero, `sum(...) / sum(...)` returns `NaN`. Argo Rollouts treats `NaN` as a failed measurement — rollout aborts even with a healthy new image.

**Fix:**
```yaml
query: |
  (
    sum(rate(nginx_ingress_controller_requests{status=~"5..",ingress="{{args.ingress-name}}"}[2m]))
    or vector(0)
  )
  /
  (
    sum(rate(nginx_ingress_controller_requests{ingress="{{args.ingress-name}}"}[2m]))
    or vector(1)
  )
```

**Impact:** Low risk, high value. Fix before first production canary rollout.

---

## 2. Enable RDS Deletion Protection

**File:** `main.tf` → `module "rds"` block

**Current:** `deletion_protection = false` (intentional for demo destroy/apply cycles)

**Fix:**
```hcl
deletion_protection = true
```

**Impact:** Prevents `terraform destroy` from dropping the production database. One-line change; enable before going live.

---

## 3. Enable S3 Terraform Remote State

**File:** `versions.tf` → `backend "s3"` block

**Current:** Bucket and DynamoDB table names are empty strings — state is stored locally.

**Fix:** Run once, then fill in:
```bash
./scripts/bootstrap-tf-state.sh us-west-1
terraform init -migrate-state
```

Fill printed values into `versions.tf`:
```hcl
backend "s3" {
  bucket         = "bookstore-terraform-state-<ACCOUNT_ID>"
  dynamodb_table = "terraform-state-lock"
  key            = "prod/terraform.tfstate"
  region         = "us-west-1"
  encrypt        = true
}
```

**Impact:** Required for team use and CI-triggered `terraform apply`. Without this, two people running `apply` concurrently corrupt state.

---

## 4. Graceful Shutdown in Node.js Backend

**File:** `backend/app.js`

**Problem:** When a pod is terminated (rolling update, scale-in), Kubernetes sends `SIGTERM`. Without a handler, Node.js exits immediately — in-flight HTTP requests return 502.

**Fix:** Add before `app.listen(...)`:
```javascript
const server = app.listen(PORT, () => console.log(`Listening on ${PORT}`));

process.on('SIGTERM', () => {
  server.close(() => {
    db.end();        // close DB connection pool
    process.exit(0);
  });
  // Force-exit after 10s if connections don't drain
  setTimeout(() => process.exit(1), 10000);
});
```

Also add `preStop` hook to the container spec in `rollout.yaml` to delay `SIGTERM` until nginx upstream is removed:
```yaml
lifecycle:
  preStop:
    exec:
      command: ["/bin/sh", "-c", "sleep 5"]
```

**Impact:** Zero dropped requests during canary rollouts and pod restarts.

---

## 5. Grafana Loki Data Source — Automated Provisioning

**File:** `modules/eks-addons/main.tf` → `helm_release.kube_prometheus_stack`

**Problem:** Loki is deployed but Grafana doesn't know about it. Currently requires a manual Grafana UI step to add the data source.

**Fix:** Add Grafana datasource via helm values:
```hcl
set {
  name  = "grafana.additionalDataSources[0].name"
  value = "Loki"
}
set {
  name  = "grafana.additionalDataSources[0].type"
  value = "loki"
}
set {
  name  = "grafana.additionalDataSources[0].url"
  value = "http://loki.monitoring.svc.cluster.local:3100"
}
set {
  name  = "grafana.additionalDataSources[0].access"
  value = "proxy"
}
```

**Impact:** Logs queryable in Grafana immediately after deploy, no manual config.

---

## 6. Grafana Admin Password via Secrets Manager

**File:** `modules/eks-addons/main.tf` → `helm_release.kube_prometheus_stack`

**Problem:** Default Grafana admin password is `prom-operator` (well-known default). No rotation.

**Fix:** Create a random password in Terraform, store in Secrets Manager, inject via helm:
```hcl
resource "random_password" "grafana_admin" {
  length  = 24
  special = false
}

resource "aws_secretsmanager_secret_version" "grafana_admin" {
  secret_id     = aws_secretsmanager_secret.grafana_admin.id
  secret_string = random_password.grafana_admin.result
}

# In helm_release.kube_prometheus_stack:
set_sensitive {
  name  = "grafana.adminPassword"
  value = random_password.grafana_admin.result
}
```

**Impact:** No default credentials. Password in Secrets Manager, rotatable.

---

## 7. RDS Enhanced Monitoring → Performance Insights

**File:** `modules/rds/main.tf`

**Current:** `performance_insights_enabled = false`

**Fix:**
```hcl
performance_insights_enabled          = true
performance_insights_retention_period = 7   # days; free tier
```

**Impact:** Query-level DB metrics visible in RDS console. Diagnose slow queries, connection spikes, lock waits without third-party tooling. `db.t3.micro` supports Performance Insights.

---

## 8. Backend Integration Tests Against Real RDS

**File:** `backend/__tests__/` — new file `integration.test.js`

**Problem:** Current vitest tests mock the DB. Schema changes, migration bugs, connection pool exhaustion — none caught by unit tests.

**Fix:** Add a CI job that spins up an RDS-compatible MySQL container and runs real queries:
```javascript
// backend/__tests__/integration.test.js
import { createPool } from '../db.js';

describe('books API — real DB', () => {
  let pool;
  beforeAll(async () => {
    pool = await createPool();
    await pool.query('CREATE TABLE IF NOT EXISTS books ...');
  });
  afterAll(() => pool.end());

  test('POST /books inserts and returns id', async () => { ... });
  test('GET /books returns list', async () => { ... });
  test('DELETE /books/:id removes row', async () => { ... });
});
```

In CI (`.github/workflows/`), add a `services.mysql` block to run the test container.

**Impact:** Catches real DB bugs before canary ships them.

---

## 9. CloudFront CDN for Frontend

**Current:** Frontend served directly from Nginx Ingress → EKS pod. Every request hits the cluster.

**Improvement:** Put AWS CloudFront in front of the frontend service:
- Static assets (`/static/*`, `/assets/*`) cached at edge globally
- Cache-Control headers set in React build
- WAF rules attached to CloudFront distribution
- Origin: `bookstore.b17facebook.xyz`

**Terraform:** Add `aws_cloudfront_distribution` resource pointing to the domain. Route53 primary record points to CloudFront instead of nginx NLB.

**Impact:** Faster page loads globally, reduced EKS pod traffic, WAF protection with no code changes.

---

## 10. OPA / Kyverno Policy Enforcement

**Problem:** Any valid YAML can be deployed — no cluster-level guardrails. A developer could deploy a privileged pod or skip resource limits.

**Improvement:** Add Kyverno (simpler than OPA Gatekeeper):
```bash
helm install kyverno kyverno/kyverno -n kyverno --create-namespace
```

Policies to enforce:
- Require `requests`/`limits` on all containers
- Disallow `privileged: true`
- Require `readOnlyRootFilesystem: true`
- Require image from ECR registry only (no `image: ubuntu:latest`)
- Require `runAsNonRoot: true`

**Impact:** Policy violations blocked at admission — bad manifests never reach scheduler.

---

## 11. Horizontal Cluster Autoscaler → Karpenter

**Current:** HPA scales pods. Node scaling uses `aws_autoscaling_group` via managed node group — slow (2-3 min per node).

**Improvement:** Replace cluster autoscaler with Karpenter:
- Provisions nodes in <60 seconds
- Selects cheapest available instance type automatically
- Consolidates underutilized nodes (cost saving)
- Spot + On-Demand mixed fleet

**Terraform:** Add Karpenter IRSA role + helm_release in `modules/eks-addons/main.tf`. Add `NodePool` and `EC2NodeClass` manifests.

**Impact:** Faster scale-out under load spikes. 30-60% cost reduction with spot instances.

---

## 12. Velero Cluster Backup

**Problem:** No backup of Kubernetes resources or PVC data (Prometheus TSDB). Cluster disaster = full rebuild.

**Improvement:** Add Velero with S3 backend:
```bash
helm install velero vmware-tanzu/velero \
  --namespace velero --create-namespace \
  --set configuration.backupStorageLocation[0].bucket=<S3_BUCKET> \
  --set configuration.backupStorageLocation[0].provider=aws
```

Schedule daily backup:
```yaml
apiVersion: velero.io/v1
kind: Schedule
spec:
  schedule: "0 2 * * *"
  template:
    includedNamespaces: [bookstore, monitoring, argocd]
    ttl: 720h   # 30 days
```

**Impact:** 30-day recovery point objective. Restore full cluster state in <30 minutes.

---

## 13. GitOps Promotion: dev → prod Pipeline

**Current:** Direct push to `k8s/overlays/prod` by CI. No staging gate.

**Improvement:** Three-stage GitOps promotion:

```
feature branch push
  → CI builds image, pushes to ECR
  → Updates k8s/overlays/dev (auto-deploy to dev namespace)
  → Dev tests pass → PR auto-created to update k8s/overlays/staging
  → Staging smoke tests pass → PR auto-created for prod
  → Manual approval → merge → ArgoCD deploys to prod
```

Each overlay is a separate ArgoCD Application pointing to a different namespace (`bookstore-dev`, `bookstore-staging`, `bookstore`).

**Impact:** No untested image ever reaches prod. Rollback = revert the overlay PR.

---

## 14. Secret Rotation Automation

**Current:** ESO refreshes DB credentials every 1h, but there's no mechanism to rotate the actual RDS password in Secrets Manager.

**Improvement:** Enable AWS Secrets Manager automatic rotation:
```hcl
resource "aws_secretsmanager_secret_rotation" "db" {
  secret_id           = module.rds.db_credentials_secret_arn   # was master_user_secret_arn (pre-phase2)
  rotation_rules {
    automatically_after_days = 30
  }
}
```

ESO will pick up the new value within 1h. Backend doesn't restart — connection pool re-establishes on next connect.

**Impact:** Credentials rotate automatically, no manual intervention, meets compliance rotation requirements.

---

## 15. Alertmanager — Slack / Email Routing

**File:** `modules/eks-addons/main.tf` → `helm_release.kube_prometheus_stack`

**Problem:** Prometheus fires alerts (PrometheusRule defined) but Alertmanager has no receivers configured. Alerts fire silently — nobody is paged.

**Fix:** Add receiver config via helm values:
```hcl
set_sensitive {
  name  = "alertmanager.config.receivers[0].name"
  value = "slack"
}
set_sensitive {
  name  = "alertmanager.config.receivers[0].slack_configs[0].api_url"
  value = var.slack_webhook_url
}
set {
  name  = "alertmanager.config.receivers[0].slack_configs[0].channel"
  value = "#bookstore-alerts"
}
set {
  name  = "alertmanager.config.route.receiver"
  value = "slack"
}
```

Store `slack_webhook_url` in Secrets Manager, inject via Terraform variable marked `sensitive = true`.

**Impact:** On-call gets paged when error rate > 1% or pod crash loops. Zero-value monitoring without this.

---

## 16. PodDisruptionBudget for Frontend

**File:** New `k8s/base/frontend/pdb.yaml`

**Problem:** Frontend runs as a `Deployment` with default replica count. During node drain (maintenance, Karpenter consolidation), all frontend pods can be evicted simultaneously → 100% downtime.

**Fix:**
```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: frontend-pdb
  namespace: bookstore
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: frontend
```

Add to `k8s/base/kustomization.yaml` resources list.

**Impact:** Node drain keeps at least 1 frontend pod running. Zero-downtime maintenance.

---

## 17. ECR Lifecycle Policies

**File:** `modules/ecr/main.tf`

**Problem:** Every CI push creates a new image tag. No cleanup → ECR storage grows unbounded. 1000 images × 200MB = 200GB = ~$9/month wasted.

**Fix:** Add lifecycle policy to each ECR repo:
```hcl
resource "aws_ecr_lifecycle_policy" "backend" {
  repository = aws_ecr_repository.backend.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 20 tagged images"
      selection = {
        tagStatus   = "tagged"
        tagPrefixList = ["v"]
        countType   = "imageCountMoreThan"
        countNumber = 20
      }
      action = { type = "expire" }
    }, {
      rulePriority = 2
      description  = "Expire untagged after 7 days"
      selection = {
        tagStatus  = "untagged"
        countType  = "sinceImagePushed"
        countUnit  = "days"
        countNumber = 7
      }
      action = { type = "expire" }
    }]
  })
}
```

Apply same policy to `bookstore-frontend` repo.

**Impact:** Bounded storage cost, no manual cleanup needed.

---

## 18. Terraform Drift Detection (Scheduled Plan in CI)

**File:** `.github/workflows/terraform-drift.yml` — new file

**Problem:** Manual changes in AWS Console (security group edits, scaling changes) diverge from Terraform state silently. Drift found only when someone runs `terraform apply` — sometimes weeks later.

**Fix:** Scheduled GitHub Actions workflow:
```yaml
on:
  schedule:
    - cron: '0 6 * * *'   # 06:00 UTC daily

jobs:
  drift:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
      - name: Configure AWS via OIDC
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: us-west-1
      - run: terraform init
      - run: terraform plan -detailed-exitcode
        id: plan
      - name: Notify on drift
        if: steps.plan.outputs.exitcode == '2'
        run: |
          curl -X POST $SLACK_WEBHOOK -d '{"text":"⚠️ Terraform drift detected — run terraform plan"}'
```

Exit code `2` = plan has changes (drift). Exit code `0` = no drift.

**Impact:** Drift caught within 24h. No surprise diffs during next `terraform apply`.

---

## 19. Secrets Manager Cross-Region Replication for DR

**File:** `modules/rds/main.tf`

**Problem:** DR runbook (Step 4) says "update `/bookstore/db-credentials` in us-east-1 with secondary RDS endpoint." But the secret only exists in us-west-1 — manual creation needed during an outage.

**Fix:** Enable automatic replication:
```hcl
resource "aws_secretsmanager_secret" "db_credentials" {
  name                    = "/bookstore/db-credentials"
  recovery_window_in_days = 0

  replica {
    region = "us-east-1"
  }
}
```

During failover: update the replicated secret's `DB_HOST` field in us-east-1, ESO in the DR cluster picks it up within 1h.

**Impact:** DR secret pre-exists in us-east-1. Eliminates one manual step during an already-stressful outage.

---

## 20. Container Image Signing (Cosign)

**File:** `.github/workflows/ci.yml` — add step after ECR push

**Problem:** ECR has IMMUTABLE tags and Trivy scanning, but nothing proves a given image was built by CI. A compromised registry credential could push a malicious image that passes tag checks.

**Fix:** Sign images after push using Sigstore Cosign (keyless, OIDC-based):
```yaml
- name: Sign image with Cosign
  uses: sigstore/cosign-installer@v3
- run: |
    cosign sign --yes \
      $ECR_REGISTRY/bookstore-backend:$IMAGE_TAG
```

Add Kyverno policy to verify signature before admission:
```yaml
rules:
- name: verify-image-signature
  match:
    resources: { kinds: [Pod] }
  verifyImages:
  - imageReferences: ["*.dkr.ecr.us-west-1.amazonaws.com/*"]
    attestors:
    - entries:
      - keyless:
          issuer: https://token.actions.githubusercontent.com
          subject: "https://github.com/KANDUKURIsaikrishna/aws_three_tier_code/*"
```

**Impact:** Only images signed by GitHub Actions CI can run in the cluster. Supply chain attack requires both ECR credential AND GitHub OIDC token compromise.

---

## 21. ResourceQuota on bookstore Namespace

**File:** New `k8s/base/quota.yaml`

**Problem:** No CPU/memory quota on `bookstore` namespace. A misconfigured rollout (e.g., canary with `requests.cpu: "4"`) can starve other namespaces on the single `t3.medium` node.

**Fix:**
```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: bookstore-quota
  namespace: bookstore
spec:
  hard:
    requests.cpu: "2"
    requests.memory: 2Gi
    limits.cpu: "4"
    limits.memory: 4Gi
    pods: "20"
```

Add to `k8s/base/kustomization.yaml` resources.

**Impact:** Prevents one bad deploy from taking down cert-manager, ESO, or monitoring.

---

## 22. EKS Cluster Upgrade Runbook

**File:** `docs/eks-upgrade-runbook.md` — new file

**Problem:** EKS 1.31 support ends ~2026-11. No documented process for upgrades. Skipping minor versions is blocked by EKS (must go 1.31 → 1.32 → 1.33). Last-minute upgrades under deadline = mistakes.

**Fix:** Document and automate the upgrade sequence:

```bash
# Step 1 — upgrade control plane
aws eks update-cluster-version \
  --name bookstore-eks \
  --kubernetes-version 1.32

# Step 2 — wait for control plane
aws eks wait cluster-active --name bookstore-eks

# Step 3 — update managed node group
aws eks update-nodegroup-version \
  --cluster-name bookstore-eks \
  --nodegroup-name bookstore-nodes

# Step 4 — update add-ons (each must match new k8s version)
terraform apply   # helm_release versions pinned in eks-addons/main.tf
```

In Terraform, update:
```hcl
# modules/eks/main.tf
cluster_version = "1.32"   # was 1.31
```

**Impact:** Controlled upgrade with known steps. Add a calendar reminder 3 months before EKS EOL.

---

## Priority Order (Suggested)

| Priority | Item | Effort | Impact |
|---|---|---|---|
| P0 | Fix AnalysisTemplate division-by-zero (#1) | 5 min | Blocks safe canary |
| P0 | Enable RDS deletion protection (#2) | 1 min | Data loss risk |
| P0 | Enable S3 Terraform state (#3) | 15 min | Team blocker |
| P0 | Alertmanager Slack/email routing (#15) | 1 hour | Silent alerts = blind ops |
| P1 | Graceful shutdown (#4) | 1 hour | User-visible 502s on deploy |
| P1 | PodDisruptionBudget frontend (#16) | 15 min | Zero-downtime node drain |
| P1 | ResourceQuota bookstore namespace (#21) | 10 min | Noisy-neighbour protection |
| P1 | Grafana Loki data source auto (#5) | 30 min | Ops friction |
| P1 | Backend integration tests (#8) | 2 hours | Quality gate |
| P1 | ECR lifecycle policies (#17) | 30 min | Unbounded storage cost |
| P2 | Terraform drift detection (#18) | 1 hour | Catch console changes daily |
| P2 | Secrets Manager cross-region replication (#19) | 15 min | DR secret missing in us-east-1 |
| P2 | Grafana admin password (#6) | 30 min | Security hygiene |
| P2 | RDS Performance Insights (#7) | 5 min | Observability |
| P2 | Secret rotation (#14) | 30 min | Compliance |
| P3 | Kyverno policies (#10) | 2 hours | Platform maturity |
| P3 | Image signing with Cosign (#20) | 2 hours | Supply chain security |
| P3 | EKS upgrade runbook (#22) | 2 hours | Ops readiness before EOL |
| P3 | CloudFront CDN (#9) | 3 hours | Performance |
| P3 | Velero backup (#12) | 2 hours | DR completeness |
| P4 | Karpenter (#11) | 1 day | Cost optimization |
| P4 | GitOps promotion pipeline (#13) | 1 day | Process maturity |
