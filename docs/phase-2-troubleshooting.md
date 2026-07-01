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

**Resolution — move Prometheus + Grafana + Loki to a dedicated EC2 instance**

Architecture change:

| Before | After |
|---|---|
| kube-prometheus-stack (6 pods, ~800 MB RAM) in EKS | Removed from EKS |
| loki-stack (2 pods, ~150 MB RAM) in EKS | Removed from EKS |
| — | `t3.small` EC2 with Docker Compose: Prometheus + Grafana + Loki |
| — | `kube-state-metrics` Helm chart only (~50 MB) |
| — | `prometheus-node-exporter` Helm chart only (~30 MB) |
| — | `promtail` Helm chart (daemonset, ~50 MB) → pushes logs to Loki on EC2 |

**EKS node RAM freed: ~950 MB**

Files changed:

| File | Change |
|---|---|
| `modules/eks-addons/observability.tf` | Replaced kube-prometheus-stack + loki with kube-state-metrics + node-exporter + promtail |
| `modules/eks-addons/gitops.tf` | ArgoCD `depends_on` updated to `helm_release.promtail` |
| `modules/eks-addons/variables.tf` | Added `loki_url` variable |
| `modules/eks-addons/outputs.tf` | Removed kube_prometheus_stack/loki outputs |
| `modules/eks/outputs.tf` | Added `cluster_security_group_id` |
| `modules/monitoring-ec2/` | New module: EC2 + SG + IAM + Docker Compose user-data |
| `main.tf` | Added `aws_eip.monitoring` + `module.monitoring_ec2` |
| `variables.tf` | Added `monitoring_admin_cidr` |
| `outputs.tf` | Replaced `loki_service_url` with `grafana_url`, `prometheus_url`, `loki_url` |

**How Prometheus scrapes EKS nodes**

`kube-state-metrics` and `prometheus-node-exporter` are exposed as NodePort services (30808, 30809). Prometheus on EC2 uses `file_sd_configs` targeting those NodePorts on EKS node private IPs. A cron job (`update-prom-targets.sh`) runs every 5 minutes and rewrites the target JSON files using `aws ec2 describe-instances --filters "Name=tag:eks:cluster-name,Values=<cluster>"`.

**How Promtail finds Loki**

An `aws_eip` is created in root before any module runs. Its `public_ip` is known at plan time. It is passed directly as `loki_url` to `module.eks_addons`, so Promtail's config has the correct Loki endpoint before EC2 even starts. Promtail retries until Loki is reachable.

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
