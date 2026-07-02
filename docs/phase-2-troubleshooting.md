# Phase 2 Troubleshooting Guide

Errors encountered during `terraform apply` of the `improvements` branch and their resolutions.

---

## TF-001 — Helm releases time out on single-node cluster

**Symptom**
```
module.eks_addons.helm_release.argocd: Still creating... [11m00s elapsed]
module.eks_addons.helm_release.kube_prometheus_stack: Still creating... [11m00s elapsed]
...
Error: context deadline exceeded
  with module.eks_addons.helm_release.argocd

Error: failed post-install: 1 error occurred:
  * timed out waiting for the condition
  with module.eks_addons.helm_release.ingress_nginx

Error: failed pre-install: 1 error occurred:
  * timed out waiting for the condition
  with module.eks_addons.helm_release.kube_prometheus_stack
```

**Root cause**

All 7 Helm charts deployed in parallel (Terraform default). A single `t3.medium` node (2 vCPU, 4 GB RAM) pulling 20+ container images simultaneously saturates CPU, memory, and network bandwidth. Pods stay `Pending` or `ContainerCreating` past the chart's `timeout`.

**Resolution — two changes**

1. **Serialize installs with `depends_on` chain** so each chart waits for the previous one to be healthy:

   ```
   cert-manager → external-secrets → ingress-nginx
     → kube-prometheus-stack → loki (parallel with argocd)
     → argo-rollouts
   ```

   Files changed:

   | File | Change |
   |---|---|
   | `modules/eks-addons/external-secrets.tf` | added `depends_on = [helm_release.cert_manager]` |
   | `modules/eks-addons/ingress.tf` | added `depends_on = [helm_release.external_secrets]` |
   | `modules/eks-addons/observability.tf` | added `helm_release.ingress_nginx` to existing `depends_on` |
   | `modules/eks-addons/gitops.tf` (argocd) | added `depends_on = [helm_release.kube_prometheus_stack]` |
   | `modules/eks-addons/gitops.tf` (argo-rollouts) | added `depends_on = [helm_release.argocd]` |

2. **Raise timeouts** to accommodate slow image pulls on a cold node:

   | Chart | Before | After |
   |---|---|---|
   | cert-manager | 300 s | 600 s |
   | external-secrets | 300 s | 600 s |
   | ingress-nginx | 300 s | 600 s |
   | kube-prometheus-stack | 600 s | 900 s |
   | loki-stack | 300 s | 600 s |
   | argo-cd | 600 s | 900 s |

**Expected total apply time after fix:** ~40 min (sequential) vs ~12 min (failed parallel).

**Commit:** `7e8fa56`

---

## TF-002 — RDS Performance Insights not supported on db.t3.micro

**Symptom**
```
Error: creating RDS DB Instance (bookstore-db): operation error RDS: CreateDBInstance,
  api error InvalidParameterCombination:
  Performance Insights not supported for this configuration.
  with module.rds.aws_db_instance.db
```

**Root cause**

`modules/rds/main.tf` had `performance_insights_enabled = true` with `performance_insights_retention_period = 7`. AWS does not support Performance Insights on `db.t3.micro`.

**Resolution**

In `modules/rds/main.tf`, disable Performance Insights:

```hcl
# before
performance_insights_enabled          = true
performance_insights_retention_period = 7

# after
# Performance Insights not supported on db.t3.micro
performance_insights_enabled = false
```

Enhanced Monitoring (`monitoring_interval = 60`) is unaffected and still active.

**Commit:** `7e8fa56`

---

## TF-003 — Secrets Manager secret already exists (not in Terraform state)

**Symptom**
```
Error: creating Secrets Manager Secret (/bookstore/db-credentials):
  ResourceExistsException: The operation failed because the secret
  /bookstore/db-credentials already exists.
  with module.rds.aws_secretsmanager_secret.db_credentials
```

**Root cause**

Secret was created by a previous `terraform apply` run but the Terraform state was lost (S3 backend bucket strings were empty in `versions.tf` — see [Known Issues](../IMPROVEMENTS_PLAN.md)). On the next apply, Terraform tries to create it again and AWS rejects it.

**Resolution — import the existing secret into state**

Run once before `terraform apply`:

```bash
terraform import \
  module.rds.aws_secretsmanager_secret.db_credentials \
  /bookstore/db-credentials
```

After import, `terraform apply` skips creation and manages the existing secret.

**If secret value is stale** (e.g., DB password rotated), also import the latest version:

```bash
# get the version ID
aws secretsmanager list-secret-version-ids \
  --secret-id /bookstore/db-credentials \
  --query 'Versions[?contains(VersionStages,`AWSCURRENT`)].VersionId' \
  --output text

# import it
terraform import \
  module.rds.aws_secretsmanager_secret_version.db_credentials \
  /bookstore/db-credentials|<VERSION_ID>
```

**Alternative — force-delete and recreate** (only safe if no live app depends on the secret):

```bash
aws secretsmanager delete-secret \
  --secret-id /bookstore/db-credentials \
  --force-delete-without-recovery
# wait ~10s, then re-run terraform apply
```

**No code change needed.** State-only fix via import.

---

## TF-004 — ACM ignore_changes redundant warning

**Symptom**
```
Warning: Redundant ignore_changes element
  on modules/acm/main.tf line 1, in resource "aws_acm_certificate" "this":
  Adding an attribute name to ignore_changes tells Terraform to ignore future
  changes to the argument in configuration after the object has been created,
  retaining the value originally configured.
  The attribute domain_validation_options is decided by the provider alone
  and therefore there can be no configured value to compare with.
```

**Root cause**

`lifecycle { ignore_changes = [domain_validation_options] }` in `modules/acm/main.tf`. The provider controls `domain_validation_options`, so `ignore_changes` on it has no effect and Terraform warns.

**Resolution**

Remove `domain_validation_options` from `ignore_changes` in `modules/acm/main.tf`.

> **Note:** This is a warning only — apply succeeds. Low priority fix.

**Status:** Open (warning, not blocking)

---

## TF-005 — Helm release created with failed status warning

**Symptom**
```
Warning: Helm release "" was created but has a failed status.
  Use the `helm` command to investigate the error, correct it,
  then run Terraform again.
  with module.eks_addons.helm_release.argocd
  (and 2 more similar warnings elsewhere)
```

**Root cause**

Terraform's Helm provider marks a release as created in state even if the pods never became Ready before the timeout. The empty release name `""` in the warning is a display artifact — the resource address shows the actual name.

**Resolution**

1. Check what's actually running:
   ```bash
   kubectl get pods -A
   helm list -A
   ```

2. Delete failed releases so Terraform can recreate them:
   ```bash
   helm uninstall argocd -n argocd
   helm uninstall ingress-nginx -n ingress-nginx
   helm uninstall kube-prometheus-stack -n monitoring
   ```

3. Remove from Terraform state to force recreation:
   ```bash
   terraform state rm module.eks_addons.helm_release.argocd
   terraform state rm module.eks_addons.helm_release.ingress_nginx
   terraform state rm module.eks_addons.helm_release.kube_prometheus_stack
   ```

4. Re-run `terraform apply` — the serialized `depends_on` chain (fix from TF-001) prevents re-occurrence.

**Root fix:** TF-001 (serialization) prevents this warning from appearing again.

---

---

## TF-006 — kube-prometheus-stack still timing out even after serialisation

**Symptom**
```
module.eks_addons.helm_release.kube_prometheus_stack: Still creating... [21m00s elapsed]
Error: context deadline exceeded
  with module.eks_addons.helm_release.kube_prometheus_stack
Warning: Helm release "" was created but has a failed status.
```

**Root cause**

Even with a 900 s timeout and a serialised `depends_on` chain, `kube-prometheus-stack` (~6 pods: Prometheus, Grafana, Alertmanager, kube-state-metrics, node-exporter, operator) saturates the single `t3.medium` node (2 vCPU, 4 GB). The images alone exceed 1.5 GB to pull on a cold node; CPU stays pegged while the operator waits for CRDs to settle.

**Resolution — move entire monitoring stack to a dedicated EC2 instance (zero monitoring pods in EKS)**

Architecture change:

| Before | After |
|---|---|
| kube-prometheus-stack (6 pods, ~800 MB RAM) in EKS | Removed from EKS entirely |
| loki-stack (2 pods, ~150 MB RAM) in EKS | Removed from EKS entirely |
| — | `t3.small` EC2 with Docker Compose: Prometheus + Grafana + Loki + kube-state-metrics |
| — | `node-exporter` v1.8.2 as **systemd service** on each EKS AL2 node (launch template) |
| — | `Fluent Bit` as **systemd service** on each EKS AL2 node → pushes logs to Loki on EC2 |

**EKS node RAM freed: ~950 MB. Zero monitoring pods in cluster.**

Files changed:

| File | Change |
|---|---|
| `modules/eks-addons/observability.tf` | Removed all Helm releases (kube-prometheus-stack, loki, kube-state-metrics, node-exporter, promtail) |
| `modules/eks-addons/gitops.tf` | ArgoCD `depends_on` updated to `helm_release.ingress_nginx` |
| `modules/eks-addons/variables.tf` | Removed `loki_url` variable |
| `modules/eks-addons/outputs.tf` | Removed `monitoring_namespace` output |
| `modules/eks/main.tf` | Added `aws_launch_template.nodes` + `aws_eks_access_entry.monitoring` |
| `modules/eks/node-user-data.sh.tftpl` | New: MIME multipart user-data installs node-exporter + Fluent Bit as systemd |
| `modules/monitoring-ec2/` | New module: EC2 + SG + IAM + Docker Compose user-data with KSM |
| `main.tf` | Added `aws_eip.monitoring` (root resource, breaks circular dep) + `module.monitoring_ec2` |
| `variables.tf` | Added `monitoring_admin_cidr` |
| `outputs.tf` | Replaced `loki_service_url` with `grafana_url`, `prometheus_url`, `loki_url` |
| `modules/security/main.tf` | Removed `rds_egress` rule (RDS never initiates outbound — dead code) |

**How Prometheus scrapes EKS nodes**

`node-exporter` runs as a systemd service on each AL2 node (port 9100). A cron job (`update-prom-targets.sh`) runs every 5 minutes on the monitoring EC2, queries `aws ec2 describe-instances --filters "Name=tag:eks:cluster-name,Values=<cluster>"`, and rewrites `/opt/monitoring/prometheus/targets/ne.json`. Prometheus uses `file_sd_configs` and hot-reloads targets automatically. The EKS cluster SG allows inbound port 9100 from the monitoring EC2 SG.

**How kube-state-metrics runs outside the cluster**

kube-state-metrics runs as a Docker Compose service on the monitoring EC2. At boot, `aws eks update-kubeconfig` generates `/root/.kube/config`. An EKS access entry grants the monitoring EC2 IAM role `AmazonEKSViewPolicy` (read-only K8s API access). kube-state-metrics mounts the kubeconfig and queries the EKS API from outside the cluster.

**EIP circular dependency avoidance**

`aws_eip.monitoring` is created as a root resource before any module runs. Its `public_ip` is known at plan time. It is passed as `loki_url` to `module.eks` (for the Fluent Bit config in the launch template) and as the EC2 host to `module.monitoring_ec2`. No circular dependency between the modules.

---

## TF-007 — RDS cross-region backup replication requires CMK KMS key

**Symptom**
```
Error: starting RDS Instance Automated Backups Replication
  (...) api error InvalidParameterValue:
  Encrypted instances require a valid KMS key ID.
  with aws_db_instance_automated_backups_replication.secondary
  on dr.tf line 4
```

**Root cause**

`dr.tf` tries to replicate RDS automated backups to the secondary region. When the source DB is encrypted with the AWS-managed key (default — `kms_key_id = null` in `modules/rds/main.tf`), AWS requires an explicit CMK in the secondary region for the replication. AWS-managed keys are region-scoped and cannot be used cross-region.

**Resolution**

Two options:

**Option A — Create a CMK and pass it (production path)**

1. Create a KMS key in `var.secondary_region`.
2. Set `dr_kms_key_id = "arn:aws:kms:<secondary-region>:<account>:key/<id>"` in `terraform.tfvars`.
3. `dr.tf` now uses `count = var.dr_kms_key_id != "" ? 1 : 0` and passes the key to the replication resource.

**Option B — Skip cross-region backup (demo default)**

Leave `dr_kms_key_id = ""` (the default). The `count = 0` skips the replication resource entirely. RDS automated backups still run within the primary region (7-day retention).

**Code change (`dr.tf`):**

```hcl
# before
resource "aws_db_instance_automated_backups_replication" "secondary" {
  provider               = aws.secondary
  source_db_instance_arn = module.rds.rds_instance_arn
  retention_period       = 7
}

# after
resource "aws_db_instance_automated_backups_replication" "secondary" {
  count                  = var.dr_kms_key_id != "" ? 1 : 0
  provider               = aws.secondary
  source_db_instance_arn = module.rds.rds_instance_arn
  retention_period       = 7
  kms_key_id             = var.dr_kms_key_id
}
```

**No code change needed for demo.** Default `dr_kms_key_id = ""` skips replication.

---

## TF-008 / K8S-001 — Security hardening (post-apply audit)

**Scope:** Not errors — proactive fixes found by code audit after the EC2 monitoring migration.

### K8S-001 — MySQL probes lacked `timeoutSeconds` (false liveness kills under load)

**File:** `k8s/base/database/mysql-statefulset.yaml`

`mysqladmin ping` can take 2–3 s when MySQL is under write pressure. The default `timeoutSeconds: 1` caused spurious liveness probe failures, triggering unnecessary pod restarts.

**Fix:** Added `timeoutSeconds: 5` and `failureThreshold: 3` to both `readinessProbe` and `livenessProbe`.

### K8S-002 — Backend resource requests/limits missing from base manifest

**File:** `k8s/base/backend/rollout.yaml`

The base rollout had no `resources` block. Only the prod overlay patched in limits. The dev overlay did not — dev backend pods ran with no CPU/memory limits and could starve other pods on the single node.

**Fix:** Added base resources (`requests: 50m CPU / 64Mi RAM; limits: 250m CPU / 128Mi RAM`). Prod overlay still overrides with higher values. Changed prod overlay `op: add` → `op: replace` (semantically correct now that base has the field).

### TF-008 — RDS egress rule allowing 0.0.0.0/0 (unnecessary blast radius)

**File:** `modules/security/main.tf`

`aws_security_group_rule.rds_egress` allowed all outbound traffic from the RDS security group. RDS never initiates connections — this rule was dead code that unnecessarily widened the attack surface.

**Fix:** Removed `rds_egress` resource entirely. No impact on RDS functionality.

### K8S-003 — Ingress-nginx missing PodDisruptionBudget

**File:** `modules/eks-addons/ingress.tf`

App-level PDBs (frontend, backend) existed in `k8s/base/pdb/pdb.yaml` but the ingress-nginx controller had none. A `kubectl drain` could evict the only ingress pod and drop all external traffic.

**Fix:** Added `controller.podDisruptionBudget.minAvailable: 1` via Helm set. Ensures at least 1 ingress pod stays available during voluntary disruptions.

**Commit:** `f541a00`

---

## CI-001 — Semgrep scan blocks CI pipeline (29 findings, exit code 1) ✅ RESOLVED

**Status:** Fixed in commits `62c0dc6` + `eebfee2`. CI passes with 0 findings.

**Symptom**

```
Run python -m pip install semgrep --quiet
semgrep scan \
  --config p/nodejs \
  --config p/owasp-top-ten \
  --config p/secrets \
  --error \
  .

┌──────────────────┐
│ 29 Code Findings │
└──────────────────┘
Ran 354 rules on 146 files: 29 findings.
Error: Process completed with exit code 1.
```

All 29 findings are `Blocking`. CI pipeline fails on the `semgrep` step and subsequent jobs do not run.

**Finding categories**

| Rule | Count | Files |
|---|---|---|
| `gha-workflow-env-secret` | 1 | `.github/workflows/ci-cd.yml:18` |
| `github-actions-mutable-action-tag` | 25 | `ci-cd.yml`, `terraform.yml`, `terraform-drift.yml` |
| `aws-ec2-launch-template-metadata-service-v1-enabled` | 1 | `modules/eks/main.tf:45` |
| `aws-ec2-has-public-ip` | 1 | `modules/monitoring-ec2/main.tf:139` |
| `ec2-imdsv1-optional` | 1 | `modules/monitoring-ec2/main.tf:139` |

---

### Fix 1 — `gha-workflow-env-secret`: move `ECR_REGISTRY` to step-level env

**File:** `.github/workflows/ci-cd.yml`

`ECR_REGISTRY` is set in the workflow-level `env:` block, making `${{ secrets.AWS_ACCOUNT_ID }}` accessible to every job including untrusted PR code.

**Fix:** Remove `ECR_REGISTRY` from workflow-level `env:`, add it only to the build step that needs it:

```yaml
# Remove from top-level env:
# ECR_REGISTRY: ${{ secrets.AWS_ACCOUNT_ID }}.dkr.ecr.us-west-1.amazonaws.com

# Add at step level inside the build job:
- name: Build and push backend image
  env:
    ECR_REGISTRY: ${{ secrets.AWS_ACCOUNT_ID }}.dkr.ecr.us-west-1.amazonaws.com
  run: |
    docker build ...
```

---

### Fix 2 — `github-actions-mutable-action-tag`: pin actions to full SHA

**Files:** all three workflow files

Mutable version tags (`@v4`, `@v2`, `@v3`) can be silently repointed — supply-chain risk (see trivy-action compromise). Pin each action to its full 40-character commit SHA.

**How to get SHAs:**

```bash
# Example — find SHA for actions/checkout@v4
gh api repos/actions/checkout/git/refs/tags/v4 --jq '.object.sha'
# If tag is annotated, dereference:
gh api repos/actions/checkout/git/tags/<sha-from-above> --jq '.object.sha'
```

**Example replacement pattern:**

```yaml
# Before (mutable)
uses: actions/checkout@v4

# After (pinned)
uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683  # v4.2.2
```

Apply to every `uses:` line across `ci-cd.yml`, `terraform.yml`, `terraform-drift.yml`. Keep the human-readable version in a comment for maintainability.

**High-priority actions to pin** (most commonly compromised):

| Action | Mutable ref used |
|---|---|
| `actions/checkout` | `@v4` |
| `actions/setup-node` | `@v4` |
| `aws-actions/configure-aws-credentials` | `@v4` |
| `aws-actions/amazon-ecr-login` | `@v2` |
| `docker/build-push-action` | `@v6` |
| `aquasecurity/trivy-action` | `@v0.28.0` |
| `github/codeql-action/upload-sarif` | `@v4` |
| `gitleaks/gitleaks-action` | `@v2` |
| `hashicorp/setup-terraform` | `@v3` |
| `actions/github-script` | `@v7` |
| `docker/setup-buildx-action` | `@v3` |

---

### Fix 3 — `ec2-imdsv1-optional`: enforce IMDSv2 on EKS launch template

**File:** `modules/eks/main.tf`

The EKS node launch template (`aws_launch_template.nodes`) does not set `metadata_options`, so IMDSv1 (unauthenticated token-free IMDS) remains available. IMDSv2 requires a session token, blocking SSRF-based metadata exfiltration.

**Fix:** Add `metadata_options` block to the launch template resource:

```hcl
resource "aws_launch_template" "nodes" {
  name_prefix = "${var.prefix}-node-"
  # ... existing config ...

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"   # enforces IMDSv2
    http_put_response_hop_limit = 2            # 2 required for containers on nodes
  }
}
```

`hop_limit = 2` is required — containers on the node need to reach IMDS through one extra network hop.

---

### Fix 4 — `ec2-imdsv1-optional`: enforce IMDSv2 on monitoring EC2

**File:** `modules/monitoring-ec2/main.tf`

Same IMDSv2 gap on the monitoring EC2 instance.

**Fix:** Add `metadata_options` to `aws_instance.monitoring`:

```hcl
resource "aws_instance" "monitoring" {
  # ... existing config ...

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
}
```

`hop_limit = 1` is fine here — no containers run on the monitoring EC2 host network.

---

### Finding accepted — `aws-ec2-has-public-ip` on monitoring EC2

**Rule:** `terraform.aws.security.aws-ec2-has-public-ip`

The monitoring EC2 requires a public IP by design — Grafana (`:3000`), Prometheus (`:9090`), Alertmanager (`:9093`) UIs are accessed from the operator's workstation via security group rules scoped to `admin_cidr_blocks`. Removing the public IP would break all monitoring access without setting up a bastion or VPN.

**Suppress with inline comment — critical gotcha:**

Semgrep anchors `aws-ec2-has-public-ip` to the **`resource` declaration line**, not to the `associate_public_ip_address` attribute line. The `# nosemgrep` comment must be on the same line as the finding anchor or it is ignored.

```hcl
# WRONG — nosemgrep on attribute line, finding anchored to resource line → still fires
resource "aws_instance" "monitoring" {
  associate_public_ip_address = true  # nosemgrep: aws-ec2-has-public-ip
}

# CORRECT — nosemgrep on the resource declaration line
resource "aws_instance" "monitoring" { # nosemgrep: aws-ec2-has-public-ip
  associate_public_ip_address = true  # intentional — SG restricts to admin_cidr_blocks
}
```

**Commit `eebfee2`** moved the comment to the correct line after the first attempt (commit `62c0dc6`) still triggered 1 finding.

---

### Priority order for fixing

1. **IMDSv2** (`Fix 3` + `Fix 4`) — Low effort, high security impact. `terraform apply` required.
2. **Move ECR_REGISTRY** (`Fix 1`) — 5-line change in ci-cd.yml.
3. **Pin action SHAs** (`Fix 2`) — Mechanical but tedious. Script with `gh api` + `sed` helps.
4. **Suppress monitoring public IP** — One comment, zero risk change.

After all fixes: `semgrep scan --config p/nodejs --config p/owasp-top-ten --config p/secrets --error .` should return exit code 0.

---

## TF-009 — Unicode character in MIME user-data crashes AL2 cloud-init ✅ RESOLVED

**Symptom**

EKS node group `CREATE_FAILED` with `NodeCreationFailure: Instances failed to join the kubernetes cluster`. EC2 console output shows:

```
UnicodeEncodeError: 'ascii' codec can't encode characters in position 222-223: ordinal not in range(128)
FAILED Failed to start Initial cloud-init job (metadata service crawler).
```

Node boots but kubelet never starts — EKS bootstrap script is never executed.

**Root cause**

`modules/eks/node-user-data.sh.tftpl` contained a `→` (Unicode U+2192) character inside a shell comment. AL2 uses **Python 2.7** for cloud-init; its MIME email parser (`email.message_from_string`) is ASCII-only. Any non-ASCII byte in MIME multipart user-data aborts `cloud-init` at the `init` stage, preventing all further user-data execution including the EKS bootstrap.

The offending line (before fix):
```bash
# Unquoted FBEOF: bash expands $${LOKI_HOST} (→ ${LOKI_HOST} after Terraform) at runtime
```

**Fix**

Rewrite the comment to use only ASCII characters. Terraform also rejects bare `${VAR}` in `.tftpl` files as unresolved template references — so both problems were in this comment.

**Commit:** `1f1892c`

**Rule for `.tftpl` files targeting AL2:**
- No Unicode characters anywhere — comments included
- All `${VAR}` must either be in the `vars` map passed to `templatefile()` or escaped as `$${VAR}`

---

## TF-010 — CloudWatch log group already exists outside Terraform state ✅ RESOLVED

**Symptom**

```
Error: creating CloudWatch Logs Log Group (/aws/vpc/flowlogs/bookstore):
  ResourceAlreadyExistsException: The specified log group already exists
  with module.network.aws_cloudwatch_log_group.vpc_flow_logs
  on modules/network/main.tf line 70
```

**Root cause**

A previous partial `terraform apply` created `/aws/vpc/flowlogs/bookstore` but the run failed before writing it to Terraform state. Subsequent applies try to `CREATE` it again.

**Fix — import into state (one-time):**

```bash
terraform import \
  module.network.aws_cloudwatch_log_group.vpc_flow_logs \
  /aws/vpc/flowlogs/bookstore
```

After import, `terraform apply` and `terraform destroy` both manage the log group correctly.

**Prevention:** This cannot recur after a clean destroy + apply cycle — destroy removes the log group, apply creates it fresh with nothing pre-existing.

---

## TF-011 — EKS node group stuck in `CREATE_FAILED` ✅ RESOLVED

**Symptom**

```
Error: waiting for EKS Node Group (bookstore-eks:bookstore-node-group) create:
  unexpected state 'CREATE_FAILED', wanted target 'ACTIVE'.
  last error: i-XXXXX: NodeCreationFailure: Instances failed to join the kubernetes cluster
```

**Root cause**

The node group entered `CREATE_FAILED` during a previous apply. A `CREATE_FAILED` node group cannot transition to `ACTIVE` — it must be deleted and recreated. Terraform's retry logic waits for the existing failed group and times out rather than replacing it.

**Fix — force replace:**

```bash
# Option A: let Terraform handle destroy + recreate in one step
terraform apply -replace=module.eks.aws_eks_node_group.this

# Option B: manual delete, then apply
aws eks delete-nodegroup \
  --cluster-name bookstore-eks \
  --nodegroup-name bookstore-node-group \
  --region us-west-1

# Poll until DELETED (~5 min)
watch -n 10 "aws eks describe-nodegroup \
  --cluster-name bookstore-eks \
  --nodegroup-name bookstore-node-group \
  --region us-west-1 \
  --query 'nodegroup.status' 2>&1"

terraform apply
```

**Underlying cause of this specific failure:** TF-009 (non-ASCII in user-data) — once TF-009 was fixed, the replacement node group bootstrapped and joined successfully.

---

## Destroy pre-flight checklist

Run these steps **before** `terraform destroy` to avoid dangling AWS resources blocking VPC deletion:

### Step 1 — Delete Kubernetes load balancers

If `ingress-nginx` was installed (via Helm), it creates an AWS NLB/ELB attached to the VPC subnets. Terraform does not know about it — if the ELB still exists when Terraform tries to delete the VPC, subnet deletion fails with a dependency violation.

```bash
# Remove ingress-nginx (deletes the NLB/ELB via Kubernetes controller)
helm uninstall ingress-nginx -n ingress-nginx
# Wait ~60s for AWS to remove the load balancer, then verify:
aws elb describe-load-balancers --region us-west-1 \
  --query 'LoadBalancerDescriptions[?contains(LoadBalancerName,`bookstore`)]'
aws elbv2 describe-load-balancers --region us-west-1 \
  --query 'LoadBalancers[?contains(LoadBalancerName,`bookstore`)]'
```

### Step 2 — Scale down ArgoCD applications (optional but safe)

ArgoCD auto-sync will try to re-create resources while Terraform is tearing them down, causing race conditions. Suspend sync before destroy:

```bash
kubectl patch application bookstore -n argocd \
  --type merge -p '{"spec":{"syncPolicy":null}}'
```

### Step 3 — Run destroy

```bash
terraform destroy
```

Terraform destroy order (automatic via dependency graph):
1. Helm releases (ArgoCD, cert-manager, external-secrets, ingress-nginx, argo-rollouts)
2. EKS access entry + policy association
3. EKS node group → EKS cluster
4. Monitoring EC2 → EIP association
5. RDS instance
6. ECR repos (`force_delete = true` handles images automatically)
7. VPC + subnets + SGs + IGW + NAT

### Step 4 — Handle known destroy edge cases

| Scenario | Symptom | Fix |
|---|---|---|
| Node group in `CREATE_FAILED` at destroy time | `Error: deleting EKS Node Group` | Usually auto-clears; if not: `aws eks delete-nodegroup --cluster-name bookstore-eks --nodegroup-name bookstore-node-group --region us-west-1` |
| VPC subnet deletion blocked by ENI | `DependencyViolation: subnet has dependencies` | Find and delete orphan ENIs: `aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=<VPC_ID>" --region us-west-1` then `aws ec2 delete-network-interface --network-interface-id <eni-id>` |
| CloudWatch log group retention | Destroy removes the group — no issue post-import | — |
| EIP not released | EIP remains allocated (billed) after destroy | `aws ec2 release-address --allocation-id <alloc-id> --region us-west-1` |
| Secrets Manager secret deletion | SM secrets have 7-day recovery window by default | `aws secretsmanager delete-secret --secret-id /bookstore/db-credentials --force-delete-without-recovery --region us-west-1` (if needed for clean re-apply) |

---

## Diagnostic commands

```bash
# check node capacity
kubectl describe node | grep -A 10 "Allocated resources"

# check all pod status
kubectl get pods -A --sort-by=.metadata.namespace

# check Helm release status
helm list -A

# check pending/failed pods
kubectl get pods -A | grep -v Running | grep -v Completed

# describe a stuck pod
kubectl describe pod <pod-name> -n <namespace>

# check events for a namespace
kubectl get events -n <namespace> --sort-by=.lastTimestamp

# check Terraform state
terraform state list | grep eks_addons

# check Secrets Manager
aws secretsmanager describe-secret --secret-id /bookstore/db-credentials
```
