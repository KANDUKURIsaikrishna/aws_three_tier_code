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

## TF-012 — Secrets Manager secret "already scheduled for deletion"

**Symptom**
```
Error: creating Secrets Manager Secret (/bookstore/grafana-admin):
  InvalidRequestException: You can't create this secret because a secret
  with this name is already scheduled for deletion.
  with module.eks_addons.aws_secretsmanager_secret.grafana_admin
  on modules/eks-addons/grafana-secret.tf line 6
```

**Root cause**

A previous `terraform destroy` (or a manual delete) removed `/bookstore/grafana-admin`, but `recovery_window_in_days = 7` on `aws_secretsmanager_secret.grafana_admin` (modules/eks-addons/grafana-secret.tf:8) means AWS soft-deletes it — the name stays reserved in "pending deletion" state for 7 days. A subsequent `terraform apply` tries to `CREATE` a secret with the same name and AWS rejects it outright (distinct from TF-003, which is `ResourceExistsException` on a live secret — this is `InvalidRequestException` on a *pending-deletion* one).

**Fix — force-delete the pending secret, then re-apply:**

```bash
aws secretsmanager delete-secret \
  --secret-id /bookstore/grafana-admin \
  --region us-west-1 \
  --force-delete-without-recovery

terraform apply
```

**Alternative — restore instead of force-delete** (keeps the old Grafana admin password instead of generating a new one):
```bash
aws secretsmanager restore-secret --secret-id /bookstore/grafana-admin --region us-west-1
# then import it into state (same procedure as TF-003) instead of letting Terraform create it
```

**Applies to any secret in this project with `recovery_window_in_days > 0`** — same failure mode can hit `/bookstore/db-credentials` (see Destroy pre-flight checklist, Step 4 table, below).

---

## TF-013 — `Kubernetes cluster unreachable: the server has asked for the client to provide credentials`

**Symptom**
```
Error: Kubernetes cluster unreachable: the server has asked for the client to provide credentials
  with module.eks_addons.helm_release.cert_manager,
  on modules/eks-addons/cert-manager.tf line 1, in resource "helm_release" "cert_manager":
```
Hits any `helm_release` in `modules/eks-addons/` — cert-manager is just whichever one runs first.

**Root cause — verified, not assumed**

`aws eks get-token` (the exec plugin in `providers.tf`'s `helm` provider block) succeeds and returns a syntactically valid `ExecCredential` token — this is NOT an expired-session or missing-CLI-creds problem. Checked with:
```bash
aws eks list-access-entries --cluster-name bookstore-eks --region us-west-1
```
which returned only:
- `arn:aws:iam::<ACCOUNT_ID>:role/aws-service-role/eks.amazonaws.com/AWSServiceRoleForAmazonEKS`
- `arn:aws:iam::<ACCOUNT_ID>:role/bookstore-eks-node-role`

The IAM principal actually running `terraform apply` (e.g. `arn:aws:iam::<ACCOUNT_ID>:user/<your-iam-user>`) has **no EKS access entry at all**. The token is valid AWS-side, but the API server has no RBAC mapping for that identity, returns 401, and client-go surfaces it as this confusing "asked for credentials" message rather than a clear "Forbidden."

This happens because `aws_eks_cluster.this` (`modules/eks/main.tf`) relies on the implicit `bootstrap_cluster_creator_admin_permissions` grant (default `true`, not set explicitly) — that grant only ever applies to whichever identity/session created the cluster. It does not transfer to a different local AWS profile, a different operator, or a CI role running later.

**Fix — grant an access entry for the principal running Terraform (immediate unblock):**

```bash
aws eks create-access-entry \
  --cluster-name bookstore-eks \
  --region us-west-1 \
  --principal-arn arn:aws:iam::<ACCOUNT_ID>:user/<your-iam-user>

aws eks associate-access-policy \
  --cluster-name bookstore-eks \
  --region us-west-1 \
  --principal-arn arn:aws:iam::<ACCOUNT_ID>:user/<your-iam-user> \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster

terraform apply
```

**Durable fix — implemented:** `modules/eks/main.tf` now has `aws_eks_access_entry.admin` + `aws_eks_access_policy_association.admin` (`for_each` over `var.admin_principal_arns`), same pattern as the monitoring EC2 role. Root `main.tf` passes `admin_principal_arns = concat([data.aws_caller_identity.current.arn], var.extra_admin_principal_arns)` — so every `apply` grants cluster-admin to whoever is currently running it, plus anyone listed in `var.extra_admin_principal_arns` (teammates, CI/CD OIDC role). No more manual CLI step, and it's tracked in state — `terraform destroy` removes it cleanly (EKS also auto-deletes access entries as part of `DeleteCluster` regardless).

**Why the CLI workaround is safe even without this fix:** EKS access entries are child resources of the cluster — `DeleteCluster` removes them automatically. Unlike ELBs/ENIs/EIPs, they never dangle in the VPC and block `terraform destroy`. The Terraform-native fix above is about not having to repeat the manual step, not about avoiding a destroy hazard.

---

## TF-014 — ArgoCD helm install times out: `context deadline exceeded` after 900s

**Symptom**
```
Warning: Helm release "" was created but has a failed status. Use the `helm` command to investigate the error, correct it, then run Terraform again.
  with module.eks_addons.helm_release.argocd,
  on modules/eks-addons/gitops.tf line 22, in resource "helm_release" "argocd":

Error: context deadline exceeded
  with module.eks_addons.helm_release.argocd,
```
`argocd-server`, `argocd-redis`, `argocd-dex-server` come up fine; `argocd-repo-server`, `argocd-application-controller`, `argocd-applicationset-controller`, `argocd-notifications-controller` sit `Pending` forever.

**Root cause — verified via `kubectl describe pod`, not assumed**

Not memory/CPU (only 24% of allocatable memory was requested at failure time — checked via `kubectl describe node`). The actual scheduler event:
```
Warning  FailedScheduling  default-scheduler  0/1 nodes are available: 1 Too many pods.
```
`kubectl get node -o json` showed `capacity.pods: "17"` — this is a **hard AWS ENI/IP ceiling** for `t3.medium` (not a resource-request limit), set once at kubelet bootstrap via the standard EKS max-pods formula. The node was already at exactly 17 running pods (kube-system: aws-node, 2x coredns, 2x ebs-csi-controller, ebs-csi-node, kube-proxy = 7; cert-manager x3; external-secrets x3; ingress-nginx x1; argocd's first 3 pods that did schedule = 3 → 17 total) before ArgoCD's remaining 4 pods even got a chance. `helm wait` then blocks until `timeout = 900` and Terraform reports `context deadline exceeded`.

This is a different failure class from TF-001/TF-006 (which were CPU/memory headroom on a single node for `kube-prometheus-stack`, since removed) — this is a pod-*count* ceiling, unrelated to how much RAM/CPU is actually free.

**Fix — chosen: add a 2nd node (within existing headroom)**

`node_max_size` was already `2` — only `node_desired_size` needed to move from `1` to `2` (`main.tf`, `module.eks`). No autoscaler (Cluster Autoscaler/Karpenter) is installed in this repo, so `max_size` alone does nothing — `desired_size` is what actually provisions the node.

**Alternative considered, not taken:** VPC CNI prefix delegation (`ENABLE_PREFIX_DELEGATION=true`) would raise the pod ceiling without a 2nd node and at no extra AWS cost, but the *already-running* node's kubelet `--max-pods` is a static value baked in at boot from AWS's standard (non-prefix) formula — enabling prefix delegation on the CNI doesn't retroactively raise it. Getting the real benefit requires the node to bootstrap with an explicit `--max-pods` override, which means calling `/etc/eks/bootstrap.sh` explicitly in `node-user-data.sh.tftpl` instead of relying on EKS's auto-injected bootstrap (see TF-009) — more moving parts in a file that has already broken twice from encoding issues. Deferred; revisit if the 2nd node's extra ~$30/mo becomes a real problem.

**Cleanup required before re-apply** (the failed release leaves state + a live Helm release behind — same pattern as TF-005):
```bash
helm uninstall argocd -n argocd   # CRDs are kept by Helm's resource policy — expected
terraform state rm module.eks_addons.helm_release.argocd
terraform apply
```

**No kubectl/helm were installed on this machine** when this was diagnosed — installed via `brew install kubectl helm` to get direct pod/scheduler evidence instead of guessing from the Terraform error text alone. Worth keeping installed for any future EKS debugging.

---

## TF-015 — `.tf` edits to delete-time-only attributes don't take effect until `apply`; destroy leaves orphans that block the next `apply`

**What happened**

During one destroy/apply cycle in this project:
1. Edited `deletion_protection = false` and `force_destroy = true` in `.tf` files, then went straight to `terraform destroy` without an intermediate `apply`. Both edits were ignored — RDS delete failed with `Cannot delete protected DB Instance`, and the CloudTrail S3 bucket delete failed with `BucketNotEmpty`, even though the config said otherwise.
2. After fixing those and completing destroy, two Secrets Manager secrets (`/bookstore/grafana-admin`, `/bookstore/db-credentials`) were left in "pending deletion" (7-day recovery window, `recovery_window_in_days = 7`), and a stray `/aws/vpc/flowlogs/bookstore` CloudWatch log group (orphaned from an even older session, never actually in Terraform state despite TF-010 claiming this was resolved) was still live. All three would have hit `terraform apply` immediately the next day with `ResourceExistsException` / `InvalidRequestException` / `ResourceAlreadyExistsException`.

**Root cause — two distinct lessons**

1. **`terraform destroy` does not run an update pass before deleting.** Attributes like `deletion_protection` and `force_destroy` are consulted from *state*, not from the `.tf` file, when a resource is being destroyed. If you change such an attribute and skip straight to `destroy`, Terraform still deletes using the last-`apply`'d value. Fix: either run `terraform apply` first (even a no-op-looking one) so the new value lands in state, or push the change live via AWS CLI directly (`aws rds modify-db-instance --no-deletion-protection`) — both work, CLI is faster when you're already mid-incident.

2. **AWS soft-delete/already-exists semantics let resources silently drift out of Terraform's view.** Secrets Manager's default recovery window, and any partially-failed `apply` that creates a resource before Terraform records it in state, both produce real AWS resources Terraform doesn't know about. The next `apply` collides with them. This project's own TF-003/TF-010 entries document the *symptom*; this entry documents the *prevention*.

**Fix — implemented**

- `modules/eks-addons/grafana-secret.tf` and `modules/rds/main.tf`: both `aws_secretsmanager_secret` resources now use `recovery_window_in_days = 0` (force delete on destroy, no soft-delete window) instead of `7`. This permanently closes the TF-012 hole for both secrets — destroy now actually removes them instead of parking them.
- Manually force-purged both pending-deletion secrets and deleted the orphaned log group via CLI so the next `apply` starts from a truly clean slate.

**Recommended pre-`apply` sanity check, whenever picking this project back up after a destroy:**
```bash
# Anything Secrets Manager thinks is still around?
aws secretsmanager list-secrets --region us-west-1 --query "SecretList[?starts_with(Name,'/bookstore')].{Name:Name,DeletedDate:DeletedDate}"

# Any log group Terraform doesn't know about?
aws logs describe-log-groups --log-group-name-prefix "/aws/vpc/flowlogs/bookstore" --region us-west-1

# Does Terraform's state match your expectation (empty after a clean destroy)?
terraform state list

# Dry-run the full build — catches config errors before you spend 20+ min applying
terraform plan
```

**Known non-blocking orphans found during this sweep, not yet cleaned up** (don't match any current resource name in the code, so they won't cause an `apply` error — just cost/clutter): an old Route53 public hosted zone for `b17facebook.xyz` (zone ID `Z09020593QE7ZCUI17J3`, predates current code, distinct from the one Terraform creates/destroys each cycle) and two old IAM roles (`bookstore-eso-role`, `bookstore-external-secrets-irsa`) from before the `eks-addons` module's current IRSA naming scheme. Safe to delete manually if you want a fully clean account, not required for `apply`/`destroy` to succeed.

---

## TF-016 — `helm_release` fails with `read: connection reset by peer` mid-install

**Symptom**
```
Warning: Helm release "" was created but has a failed status. Use the `helm` command to investigate the error, correct it, then run Terraform again.
  with module.eks_addons.helm_release.external_secrets,

Error: 2 errors occurred:
	* Post "https://<cluster-id>.yl4.us-west-1.eks.amazonaws.com/apis/apiextensions.k8s.io/v1/customresourcedefinitions?...": read tcp 192.168.x.x:xxxxx-><eks-ip>:443: read: connection reset by peer
```
Hit on `external_secrets`, but this can land on any `helm_release` in `modules/eks-addons/` — whichever one happens to be mid-install when the network blips.

**Root cause**

A TCP-level reset mid-request, not a config or logic bug. Helm installs a chart's CRDs (`apiextensions.k8s.io/v1/customresourcedefinitions`) before the rest of its templates; if that specific POST gets reset, Helm aborts and marks the whole release `failed` — even though, in this case, the Deployments/pods had already been applied and came up `Running` fine (verified via `kubectl get pods -n external-secrets` and `kubectl get crd | grep external-secrets.io` — all 24 CRDs and all 3 pods were actually present).

Likely cause: a local network interruption (this ran from a home laptop over `192.168.x.x`, apply had already been running 28+ minutes for the RDS instance alone) or a mid-size CRD payload hitting a path-MTU/proxy blip on the way to the EKS public endpoint. Not reproduced on immediate retry, so treated as transient rather than chased further — see `superpowers:systematic-debugging`: a transient, non-reproducible network error after confirming the underlying resources are actually healthy is a legitimate stopping point, not "no root cause found."

**Fix**

None needed in code. Terraform's Helm provider (v2.17+) detects the `failed` release status on the next `apply` and repairs it in place — no manual `helm uninstall` / `terraform state rm` required this time (unlike TF-005, which was a genuine stuck-state case). Just re-run:
```bash
terraform apply
```
If it fails the same way repeatedly (not just once), then treat it as TF-005 instead — uninstall + state rm + reapply.

**One-time gotcha this surfaced:** after a cluster is destroyed and recreated, its EKS API endpoint hostname changes (new cluster ID in the URL). Local `kubectl`/`helm` CLI commands will fail with `dial tcp: ... no such host` if your kubeconfig still points at the old, now-deleted cluster. Terraform itself is unaffected (its Helm/Kubernetes provider reads `module.eks.cluster_endpoint` fresh every run), but you'll need to refresh your own shell:
```bash
aws eks update-kubeconfig --name bookstore-eks --region us-west-1
```

---

## TF-017 — Kubernetes-provisioned AWS resources (LoadBalancers, log groups) invisible to `terraform destroy`

**What happened**

Two separate resources kept surviving `terraform destroy` with **zero error reported**, then blocked the next `apply`:
1. `ingress-nginx`'s Kubernetes `Service` (`type=LoadBalancer`) provisions a real AWS NLB as a side effect of the Kubernetes cloud-controller-manager reacting to the Service spec — Terraform's state only knows about the `helm_release`, never calls the AWS API for the NLB itself, so it's structurally invisible to `terraform destroy`. Left alone, it blocks VPC/subnet deletion with `DependencyViolation`.
2. `/aws/vpc/flowlogs/bookstore` (`modules/network/main.tf`, plain `aws_cloudwatch_log_group`, no `lifecycle` block) reappeared after a "clean" destroy **three times**, with `terraform state list` confirmed empty afterward each time. **Root cause found 2026-07-21** via `aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=CreateLogGroup` (the earlier `AttributeKey=ResourceName` query was a dead end — known CloudTrail limitation for this event type, don't bother with it): two `CreateLogGroup` events, one by `saikrishna` (Terraform, normal), one immediately after by `vpc-flow-logging+<account-id>` — **AWS's own VPC Flow Logs service self-healing its destination log group.** `aws_iam_role_policy.vpc_flow_log` grants that service `logs:CreateLogGroup` (needed for it to work at all); if the log group vanishes while `aws_flow_log.vpc` is still actively delivering records, the service just recreates it using that same permission. The 3rd occurrence was actually caused by the *fix* below — its original version had no ordering relative to `aws_flow_log.vpc`, only an implicit dependency on the log group itself, so it could (and did) race ahead and delete the log group while flow logs were still live.

**Fix — implemented**

Both now have a `null_resource` with a `destroy`-time `local-exec` provisioner that force-deletes the AWS-side resource directly:
- `modules/eks-addons/ingress.tf` — `null_resource.delete_ingress_nginx_lb`: `kubectl delete svc ingress-nginx-controller -n ingress-nginx`, then a 30s sleep for AWS to actually deprovision the NLB before Terraform reaches the VPC.
- `modules/network/main.tf` — `null_resource.force_delete_flow_log_group`: explicit `depends_on = [aws_flow_log.vpc]` (the actual fix — ensures flow-log delivery has stopped before the log group is deleted), plus a 15s sleep for any in-flight delivery to fully drain, then `aws logs delete-log-group`.

Both are best-effort (`|| true` throughout) — they need `kubectl`/`aws` CLI available on whatever machine runs `terraform destroy`; if those binaries are missing (e.g. a bare CI runner), the provisioner silently no-ops and you're back to the manual cleanup below.

**Validated:** the ingress-nginx fix has now worked cleanly across multiple `terraform destroy` runs — NLB gone every time, no manual `helm uninstall` step needed. The log group fix's *previous* version reliably failed to prevent recreation (that's how the root cause above was found); the `depends_on` version is not yet validated against a real destroy — confirm on the next cycle and update this entry.

**Manual fallback, if the provisioners don't fire for any reason:**
```bash
kubectl delete svc ingress-nginx-controller -n ingress-nginx --ignore-not-found
aws logs delete-log-group --log-group-name "/aws/vpc/flowlogs/bookstore" --region us-west-1
```

**Added `null` provider** to `versions.tf` (`hashicorp/null ~> 3.0`) — ran `terraform init` to install it. If you see `Missing required provider` for `null`, run `terraform init` again.

---

## TF-018 — `terraform apply` taking ~1 hour; parallelized the Helm addon chain

**What was slow**

Full `apply` cycles were approaching an hour. Broke down the actual critical path instead of guessing:
- RDS Multi-AZ creation (~28 min observed) — **not actually the bottleneck**. Nothing in `module.eks_addons` depends on `module.rds`, so Terraform already creates them in parallel; RDS's time is absorbed under the EKS/addons critical path rather than adding to it.
- The real serial chain: `modules/eks-addons/` had `cert_manager → external_secrets → ingress_nginx → argocd → argo_rollouts`, each `depends_on` the previous one, each with its own `wait=true` + up-to-900s timeout. This was written in TF-001, when the cluster ran a **single node** and couldn't tolerate concurrent Helm installs. By the time this was revisited, the cluster had already moved to 2 nodes (TF-014) and `kube-prometheus-stack` was long gone (moved to EC2) — the original resource-contention justification for full serialization no longer fully applied, but the `depends_on` chain was never revisited.

**Fix — implemented**

`cert-manager`, `external-secrets`, and `ingress-nginx` now install **concurrently** — removed the artificial `depends_on` between them in `modules/eks-addons/external-secrets.tf` and `modules/eks-addons/ingress.tf`. None of the three have a real functional dependency on each other. Kept:
- `argocd` still waits for `ingress-nginx` (soft dependency — its Ingress resource wants the `nginx` IngressClass to exist)
- `argo-rollouts` still waits for `argocd` (left as-is, not revisited — it's normally fast, so serializing it costs little)

**Trade-off, accepted knowingly:** 2 nodes is more headroom than the 1-node setup this chain was built for, but not unlimited — if concurrent installs reintroduce resource-contention failures (the TF-001/TF-006 class), that's the signal to partially re-serialize rather than assume something else broke. Check node capacity (`kubectl describe node | grep -A10 "Allocated resources"`) before re-adding `depends_on` links reflexively.

**Not touched:** RDS `multi_az`. Disabling it would speed up RDS creation further, but it's a real HA feature this project's own `test_multi_az_failover.py` (see `docs/superpowers/specs/2026-07-08-cross-region-dr-design.md`) depends on being `true` to test at all — cutting it for apply speed would directly undercut DR testing that was just designed.

---

## Destroy pre-flight checklist

Run these steps **before** `terraform destroy` to avoid dangling AWS resources blocking VPC deletion:

### Step 1 — Delete Kubernetes load balancers (now automatic — see TF-017)

If `ingress-nginx` was installed (via Helm), it creates an AWS NLB/ELB attached to the VPC subnets. Terraform does not know about it — if the ELB still exists when Terraform tries to delete the VPC, subnet deletion fails with a dependency violation.

**As of TF-017, this is handled automatically** by `null_resource.delete_ingress_nginx_lb` in `modules/eks-addons/ingress.tf` — it deletes the Service (and waits 30s for AWS to deprovision the NLB) as part of `terraform destroy` itself. Validated working — no manual step needed. Only fall back to the manual command below if the provisioner didn't fire (e.g. `kubectl`/`aws` CLI missing on the machine running destroy) and you see a `DependencyViolation` on subnet deletion:

```bash
# Manual fallback only
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
| CloudWatch log group survives destroy | `/aws/vpc/flowlogs/bookstore` reappears, blocks next apply (TF-010) | `null_resource.force_delete_flow_log_group` in modules/network/main.tf handles this now (TF-017) — belt-and-suspenders, not a real root-cause fix. Fallback: `aws logs delete-log-group --log-group-name "/aws/vpc/flowlogs/bookstore" --region us-west-1` |
| EIP not released | EIP remains allocated (billed) after destroy | `aws ec2 release-address --allocation-id <alloc-id> --region us-west-1` |
| Secrets Manager secret deletion | SM secrets have 7-day recovery window by default — affects both `/bookstore/db-credentials` and `/bookstore/grafana-admin` (see TF-012) | `aws secretsmanager delete-secret --secret-id <secret-id> --force-delete-without-recovery --region us-west-1` (if needed for clean re-apply) |

---

## TF-019 — Network drops mid-apply: DNS failures, errored.tfstate, stuck DynamoDB lock

**Symptom**

Multiple errors across unrelated resources in a single apply, all sharing the same pattern — DNS resolution failure against AWS service hostnames:

```
Error: failed to upload state: operation error S3: PutObject, ...
  Put "https://bookstore-terraform-state-<ACCOUNT_ID>-ca.s3.us-west-1.amazonaws.com/...":
  dial tcp: lookup bookstore-terraform-state-<ACCOUNT_ID>-ca.s3.us-west-1.amazonaws.com:
  no such host

Error: waiting for EKS Add-On (bookstore-eks:aws-ebs-csi-driver) create: ...
  dial tcp: lookup eks.us-west-1.amazonaws.com: no such host

Error: waiting for RDS DB Instance (bookstore-db) create: ...
  dial tcp: lookup rds.us-west-1.amazonaws.com: no such host

Error: Error releasing the state lock
  dial tcp: lookup dynamodb.us-west-1.amazonaws.com: no such host

Error: Failed to persist state to backend
  The error shown above has prevented Terraform from writing the updated state
  to the configured backend. To allow for recovery, the state has been written
  to the file "errored.tfstate" in the current working directory.
```

Alongside these, Helm releases show `http2: client connection lost` to the EKS API endpoint and any `helm_release` or `aws_eks_addon` in-flight at that moment errors out.

**Root cause**

Local network (WiFi / VPN / DNS resolver) dropped mid-apply. Terraform was in the middle of creating 6–8 resources concurrently; all outstanding AWS API calls failed to resolve DNS. This is **not a code or configuration bug** — nothing in the Terraform files is wrong. The partial resource creation (some resources already created before the drop) plus the failed state push is what requires manual recovery steps.

**Compound: S3 bucket name mismatch**

The error URL above shows `bookstore-terraform-state-<ACCOUNT_ID>-ca` — with a `-ca` suffix not generated by `scripts/bootstrap-tf-state.sh` (which creates `bookstore-terraform-state-<ACCOUNT_ID>`, no suffix). If the bucket name in `versions.tf` has a suffix that doesn't exist, DNS will also fail (`no such host`) even when the network is fine. Verify:

```bash
# whichever returns 200/no error is the real bucket
aws s3api head-bucket --bucket bookstore-terraform-state-<ACCOUNT_ID> --region us-west-1
aws s3api head-bucket --bucket bookstore-terraform-state-<ACCOUNT_ID>-ca --region us-west-1
```

Fix `versions.tf` `backend "s3"` `bucket` field to match the bucket that actually exists, then run `terraform init -reconfigure`.

**Recovery sequence — run in order**

**Step 1 — confirm network is back**
```bash
aws sts get-caller-identity
# must succeed before continuing
```

**Step 2 — force-unlock the stuck DynamoDB state lock**
```bash
# Lock ID is printed in the "Error: Error releasing the state lock" message
terraform force-unlock 82d71b91-713d-a513-85ff-410ce252e18e
```
Confirm with:
```bash
aws dynamodb get-item \
  --table-name terraform-state-lock \
  --key '{"LockID": {"S": "bookstore-terraform-state-<ACCOUNT_ID>/prod/terraform.tfstate"}}' \
  --region us-west-1
# should return no Item, or an empty result
```

**Step 3 — push errored.tfstate to S3** (recover partial resource state before next apply)
```bash
terraform state push errored.tfstate
# Terraform instructs this exact command in the "Failed to persist state" error text
```

**Step 4 — import any resources created but not in state**

After the drop, some resources may have been created in AWS but not recorded in state. The most common are:
- CloudWatch log group (TF-010): `terraform import module.network.aws_cloudwatch_log_group.vpc_flow_logs /aws/vpc/flowlogs/bookstore`
- Secrets Manager secret (TF-003): `terraform import module.rds.aws_secretsmanager_secret.db_credentials /bookstore/db-credentials`

Run `terraform plan` — it will surface `Error: already exists` for any such resource, revealing exactly which imports are needed.

**Step 5 — re-run apply**
```bash
terraform apply
```

Resources already created (RDS instance, VPC, etc.) will show no change; resources that errored mid-create will be retried.

**Prevention**

No code change prevents a network drop. Mitigations:
- Run Terraform from a stable wired connection or from an EC2 instance in the same region (no cross-internet dependency).
- Keep `errored.tfstate` as a safety net — never delete it until you have confirmed `terraform state push errored.tfstate` succeeded and `terraform plan` shows the expected state.
- Run `terraform apply` in a `tmux`/`screen` session so a disconnect doesn't kill the process.

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
