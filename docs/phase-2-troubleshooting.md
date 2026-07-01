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
