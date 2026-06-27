# Phase 2 — Future Improvements

> These are targeted, incremental improvements to the existing Phase 2 architecture.
> Each item is self-contained — implement in any order based on priority.
> Phase 3 (second region EKS, full active-active) is tracked separately.

---

## 1. Fix Division-by-Zero in AnalysisTemplate ✅ Implemented

**File:** `k8s/base/monitoring/analysis-template.yaml`

Fixed. Numerator guards with `or vector(0)`, denominator with `or vector(1)`. Zero-traffic canary no longer aborts.

---

## 2. Enable RDS Deletion Protection ✅ Implemented

**File:** `main.tf` → `module "rds"` block

`deletion_protection = true` set. `terraform destroy` now requires manual disable first.

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

## 5. Grafana Loki Data Source — Automated Provisioning ✅ Implemented

**File:** `modules/eks-addons/main.tf`

Loki datasource (`additionalDataSources[0]`) auto-provisioned in kube_prometheus_stack helm values. Logs visible in Grafana on first login, no manual step.

---

## 6. Grafana Admin Password via Secrets Manager ✅ Implemented

**File:** `modules/eks-addons/main.tf`

`random_password.grafana_admin` (24 chars, no specials) created. Stored at `/bookstore/grafana-admin` in Secrets Manager. Injected via `set_sensitive { grafana.adminPassword }`. ARN in `grafana_admin_secret_arn` output.

Retrieve password: `aws secretsmanager get-secret-value --secret-id /bookstore/grafana-admin --query SecretString --output text`

---

## 7. RDS Enhanced Monitoring → Performance Insights ✅ Implemented

**File:** `modules/rds/main.tf`

`performance_insights_enabled = true`, `performance_insights_retention_period = 7` (free tier, 7-day window).

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

## 9. CloudFront CDN for Frontend ✅ Implemented

**Files:** `main.tf`, `variables.tf`, `outputs.tf`

`aws_cloudfront_distribution.frontend` created (gated on `enable_cloudfront = true`). ACM cert auto-created in us-east-1 via `aws.secondary` provider (CloudFront requirement). Static assets cached at edge (`/static/*` TTL 7d). `cloudfront_domain` Terraform output added.

**Enable:**
```hcl
# terraform.tfvars
enable_cloudfront = true
primary_alb_dns   = "<nginx-nlb-hostname>"
```
Then `terraform apply`.

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

## 14. Secret Rotation Automation ✅ Implemented

**Files:** `modules/rds/main.tf`, `modules/rds/variables.tf`

`aws_secretsmanager_secret_rotation.db_credentials` added (count=0 when `rotation_lambda_arn=""`, count=1 when ARN provided). Variables `rotation_lambda_arn` (default `""`) and `rotation_days` (default `30`) added.

**To activate:** Deploy the [AWS single-user MySQL rotation Lambda](https://github.com/aws-samples/aws-secrets-manager-rotation-lambdas) then:
```hcl
# terraform.tfvars
rotation_lambda_arn = "arn:aws:lambda:us-west-1:<ACCOUNT_ID>:function:SecretsManagerMySQLRotation"
```

ESO picks up rotated value within 1h — no pod restart needed.

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

## 16. PodDisruptionBudget for Frontend ✅ Already Implemented

**File:** `k8s/base/pdb/pdb.yaml`

Both `backend-pdb` and `frontend-pdb` (`minAvailable: 1`) are present and included in `k8s/base/kustomization.yaml`. No action needed.

---

## 17. ECR Lifecycle Policies ✅ Already Implemented

**File:** `modules/ecr/main.tf`

`aws_ecr_lifecycle_policy` resource exists, applied to all repos via `for_each`. Retains last `var.image_retention_count` images (default 10). No action needed.

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

---

## 23. VPC Flow Logs ✅ Implemented

**File:** `modules/network/main.tf`

All VPC traffic (ACCEPT + REJECT) logged to CloudWatch Logs `/aws/vpc/flowlogs/bookstore`. 90-day retention. Dedicated IAM role with least-privilege. Enables post-incident network forensics and GuardDuty data enrichment.

---

## 24. GuardDuty Threat Detection ✅ Implemented

**File:** `main.tf`

`aws_guardduty_detector` enabled with:
- S3 data event monitoring
- EKS audit log analysis (detects privilege escalation, crypto-mining, lateral movement)
- EC2 malware scanning on EBS volumes

Findings surface in AWS Security Hub and can be routed to SNS/Slack via EventBridge.

---

## 25. CloudTrail Audit Logging ✅ Implemented

**File:** `main.tf`

`aws_cloudtrail.main` — multi-region trail with:
- Log file validation (SHA-256 digest chain, tamper detection)
- Encrypted S3 bucket (`AES256`, versioning enabled, public access blocked)
- Global service events (IAM, STS, CloudFront)
- Dedicated S3 bucket with scoped bucket policy (CloudTrail service principal only)

Required for compliance (SOC2, PCI-DSS, ISO27001) and forensic investigation.

---

## 26. RDS Final Snapshot + SM Recovery Window ✅ Implemented

**Files:** `modules/rds/main.tf`, `modules/rds/variables.tf`, `main.tf`

- `skip_final_snapshot = false` in prod — RDS creates a snapshot before any destroy. Snapshot identifier: `<db-identifier>-final-snapshot`.
- `recovery_window_in_days = 7` on Secrets Manager secret (was `0` — immediate permanent deletion).

`skip_final_snapshot` exposed as module variable; defaults to `false` for safety.

---

## 27. GitHub OIDC Trust Policy — Branch Restriction ✅ Implemented

**File:** `iam.tf`

`StringLike` condition changed from `"repo:KANDUKURIsaikrishna/aws_three_tier_code:*"` (all refs, including PRs from forks) to:
```
["repo:KANDUKURIsaikrishna/aws_three_tier_code:ref:refs/heads/main",
 "repo:KANDUKURIsaikrishna/aws_three_tier_code:ref:refs/heads/improvements"]
```

Fork PRs and arbitrary branch pushes can no longer assume the AWS role.

---

## 28. CODEOWNERS ✅ Implemented

**File:** `.github/CODEOWNERS`

All paths default to `@KANDUKURIsaikrishna`. Specific paths (`.github/`, `*.tf`, `k8s/`, `iam.tf`) listed explicitly so GitHub enforces review on high-blast-radius changes regardless of PR author.

---

## 29. CI Action Version Pinning ✅ Implemented

**Files:** `.github/workflows/ci-cd.yml`, `.github/workflows/terraform.yml`

`aquasecurity/trivy-action@master` (floating, supply-chain risk) pinned to `@v0.28.0`. `timeout-minutes: 30` added to `deploy` job to prevent approval accumulation.

> **Next step:** Pin all remaining actions to commit SHAs (e.g., `actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683`) for full supply-chain hardening. Dependabot can automate SHA bump PRs.

---

## 30. Backend /health Endpoint + Probe Fix ✅ Implemented

**Files:** `backend/app.js`, `k8s/base/backend/rollout.yaml`

Added `GET /health → 200 { status: "ok" }` to Express app. Rollout readiness and liveness probes updated from `/` to `/health`. Isolates health signal from application routing — `/` could return 4xx without making the pod unready.

---

## 31. MySQL Image Pin + Capability Hardening ✅ Implemented

**File:** `k8s/base/database/mysql-statefulset.yaml`

Image pinned `mysql:8.0` → `mysql:8.0.39` (deterministic builds). Container securityContext extended: drop ALL capabilities, re-add only `CHOWN SETUID SETGID DAC_OVERRIDE` (minimum MySQL init requires). `allowPrivilegeEscalation: false` already present.

---

## 32. EKS API Endpoint CIDR Restriction ✅ Implemented

**Files:** `modules/eks/main.tf`, `modules/eks/variables.tf`

`public_access_cidrs` variable added (default `["0.0.0.0/0"]` — backwards compatible). Set to your admin IP range in `terraform.tfvars` before production go-live:
```hcl
# terraform.tfvars
eks_public_access_cidrs = ["203.0.113.0/32"]  # your office/VPN egress IP
```

---

## 33. .gitignore Hardening ✅ Implemented

- `.terraform.lock.hcl` removed from ignore list — now tracked (like `package-lock.json`). Ensures reproducible `terraform init` across team and CI.
- Added: `.env.prod`, `.env.staging`, `.env.production`, `*.env.*`
- SSH key wildcard broadened: explicit `id_rsa`, `id_ed25519` → `id_*` (catches all key types)
- Added: `*.tfstate.backup`, `*.p12`, `*.pfx`

---

## Priority Order (Suggested)

| Priority | Item | Effort | Impact |
|---|---|---|---|
| P0 | ~~Fix AnalysisTemplate division-by-zero (#1)~~ | ✅ done | Blocks safe canary |
| P0 | ~~Enable RDS deletion protection (#2)~~ | ✅ done | Data loss risk |
| P0 | ~~VPC Flow Logs (#23)~~ | ✅ done | Network forensics + GuardDuty feed |
| P0 | ~~GuardDuty threat detection (#24)~~ | ✅ done | Runtime threat detection |
| P0 | ~~CloudTrail audit logging (#25)~~ | ✅ done | Compliance + forensics |
| P0 | Enable S3 Terraform state (#3) | 15 min | Team blocker |
| P0 | Alertmanager Slack/email routing (#15) | 1 hour | Silent alerts = blind ops |
| P1 | ~~OIDC branch restriction (#27)~~ | ✅ done | Fork PRs can't assume AWS role |
| P1 | ~~RDS final snapshot + SM recovery window (#26)~~ | ✅ done | Data recovery safety |
| P1 | ~~CODEOWNERS (#28)~~ | ✅ done | Enforced code review |
| P1 | ~~Backend /health endpoint (#30)~~ | ✅ done | Accurate readiness signal |
| P1 | ~~MySQL image pin + caps (#31)~~ | ✅ done | Deterministic builds |
| P1 | Graceful shutdown (#4) | 1 hour | User-visible 502s on deploy |
| P1 | ~~PodDisruptionBudget frontend (#16)~~ | ✅ done | Zero-downtime node drain |
| P1 | ~~ResourceQuota bookstore namespace (#21)~~ | ✅ done | Noisy-neighbour protection |
| P1 | ~~Grafana Loki data source auto (#5)~~ | ✅ done | Ops friction |
| P1 | Backend integration tests (#8) | 2 hours | Quality gate |
| P1 | ~~ECR lifecycle policies (#17)~~ | ✅ done | Unbounded storage cost |
| P2 | ~~Terraform drift detection (#18)~~ | ✅ done | Catch console changes daily |
| P2 | ~~Secrets Manager cross-region replication (#19)~~ | ✅ done | DR secret missing in us-east-1 |
| P2 | ~~Grafana admin password (#6)~~ | ✅ done | Security hygiene |
| P2 | ~~RDS Performance Insights (#7)~~ | ✅ done | Observability |
| P2 | ~~Secret rotation (#14)~~ | ✅ done | Compliance |
| P2 | ~~CI action version pinning (#29)~~ | ✅ done | Supply-chain hardening |
| P2 | ~~EKS public_access_cidrs (#32)~~ | ✅ done | Narrow attack surface |
| P2 | ~~.gitignore hardening (#33)~~ | ✅ done | Prevent accidental secret commit |
| P3 | Kyverno policies (#10) | 2 hours | Platform maturity |
| P3 | Image signing with Cosign (#20) | 2 hours | Supply chain security |
| P3 | ~~EKS upgrade runbook (#22)~~ | ✅ done | Ops readiness before EOL |
| P3 | ~~CloudFront CDN (#9)~~ | ✅ done | Performance |
| P3 | Velero backup (#12) | 2 hours | DR completeness |
| P4 | Karpenter (#11) | 1 day | Cost optimization |
| P4 | GitOps promotion pipeline (#13) | 1 day | Process maturity |
