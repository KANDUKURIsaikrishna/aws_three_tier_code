# Session Summary — 2026-06-26

## What This Session Accomplished

This session completed the Phase 2 improvements branch and fixed architectural misalignments vs. the original intent (RDS-only database, multi-region infrastructure, minimal demo sizing). All changes are on the `improvements` branch.

---

## 1. Documentation Written

Two permanent reference docs created:

| File | Purpose |
|---|---|
| `docs/phase-2-implementation.md` | Technical reference: how each system works, config values, commands |
| `docs/phase-2-improvements.md` | Delta vs Phase 1: what changed, why, and what's next |

---

## 2. In-Cluster MySQL Removed (PV/PVC Elimination)

**Problem:** MySQL StatefulSet + PVC was still deployed inside EKS, contradicting the intent to use managed RDS exclusively.

**Changes:**

| File | Change |
|---|---|
| `k8s/base/kustomization.yaml` | Removed `database/mysql-init-configmap.yaml`, `database/mysql-service.yaml`, `database/mysql-statefulset.yaml` |
| `k8s/base/configmaps/backend-config.yaml` | `DB_HOST` changed from `mysql-service` → `REPLACE_WITH_RDS_ENDPOINT` |
| `k8s/base/network-policy/network-policy.yaml` | Removed `mysql-policy` (pod selector). Backend egress now targets VPC CIDR `170.20.0.0/16:3306` (RDS in private subnets) |

**Result:** No PVCs for database. RDS handles HA, backups, point-in-time recovery. Backend connects to RDS endpoint set in ConfigMap.

> **Operator action after `terraform apply`:**
> ```bash
> terraform output rds_endpoint
> # Update k8s/base/configmaps/backend-config.yaml DB_HOST with that value
> ```

---

## 3. Observability Stack Completed

### What was already done (prior session)
- `kube-prometheus-stack` (Prometheus + Grafana) in `modules/eks-addons/main.tf`
- `ServiceMonitor` for backend `/metrics` scraping

### What was added this session

**Loki log aggregation** (`modules/eks-addons/main.tf`):
- `helm_release.loki` using `grafana/loki-stack`
- Promtail DaemonSet ships container logs from all pods
- Reuses existing Grafana from `kube-prometheus-stack` (no duplicate)
- No PVC (demo mode) — logs are in-memory

**Alertmanager enabled** (`modules/eks-addons/main.tf`):
- Was: `alertmanager.enabled = "false"`
- Now: `alertmanager.enabled = "true"`, 1 replica

**Alert rules** (`k8s/base/monitoring/prometheus-rules.yaml`):

| Alert | Condition | Severity |
|---|---|---|
| `PodCrashLooping` | Restart rate >1/min for 5m in `bookstore` namespace | critical |
| `HighErrorRate` | Nginx 5xx rate >5% for 2m on `bookstore-ingress` | warning |
| `DBConnectionExhaustion` | `nodejs_active_handles_total` >90 for 1m | warning |

---

## 4. Canary Deployment Upgraded

### Before
```
10% → 30s → 50% → 30s → 100%
```
No automated rollback. Manual abort only.

### After (`k8s/base/backend/rollout.yaml` + `k8s/base/monitoring/analysis-template.yaml`)
```
10% → analysis → 30s → 25% → 30s → 50% → analysis → 60s → 100%
```

**AnalysisTemplate** (`error-rate`):
- Queries Prometheus every 30s for nginx 5xx rate on `bookstore-ingress`
- `successCondition: result[0] < 0.01` (less than 1% error rate)
- `failureLimit: 2` — two consecutive failures trigger automatic rollback
- Prometheus address: `http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090`

**Rollback flow:** Argo Rollouts detects analysis failure → `kubectl argo rollouts abort backend` auto-triggered → traffic returns 100% to stable revision.

---

## 5. Multi-Region Active-Passive Failover

### Architecture

```
                    Route53 Health Check
                           │
                    ┌──────▼──────┐
                    │   Route53   │  failover routing policy
                    │  Public Zone│
                    └──┬───────┬──┘
                       │       │
               PRIMARY │       │ SECONDARY
              (us-west-1)     (us-east-1)
                   │               │
            EKS + nginx       (deploy when needed)
            RDS primary        RDS restore from backup
```

### Terraform changes

**`variables.tf`** — new variables:
```hcl
variable "secondary_region"  { default = "us-east-1" }
variable "primary_alb_dns"   { default = "" }   # fill post-deploy
variable "secondary_alb_dns" { default = "" }   # fill after secondary EKS
```

**`main.tf`** — new resources:

| Resource | Purpose |
|---|---|
| `provider "aws" { alias = "secondary" }` | Provider alias for us-east-1 |
| `aws_db_instance_automated_backups_replication.secondary` | RDS automated backups replicated to us-east-1, 7-day retention |
| `aws_ecr_replication_configuration.secondary` | All `bookstore-*` ECR images mirrored to us-east-1 registry |
| `aws_route53_zone.public` | Public hosted zone for `var.domain` |
| `aws_route53_health_check.primary` | HTTPS health check on primary domain, 30s interval, 3 failure threshold |
| `aws_route53_record.primary` | CNAME → primary nginx NLB, failover=PRIMARY (gated by `primary_alb_dns != ""`) |
| `aws_route53_record.secondary` | CNAME → secondary nginx NLB, failover=SECONDARY (gated by `secondary_alb_dns != ""`) |

**`modules/rds/outputs.tf`** — added `rds_instance_arn` (required by replication resource).

**`outputs.tf`** — added `route53_public_zone_id`, `route53_public_name_servers`, `loki_service_url`.

### Two-phase apply procedure

```bash
# Phase 1 — provision infrastructure
terraform apply

# Get primary ALB DNS
kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# Phase 2 — wire Route53 records
# Set primary_alb_dns in terraform.tfvars
terraform apply

# Point your registrar NS records to Route53 name servers:
terraform output route53_public_name_servers
```

### DR Runbook (passive region promotion)

1. Health check fires → Route53 automatically routes to `secondary_alb_dns`
2. In us-east-1: restore RDS from replicated backup → new instance
3. Deploy EKS in us-east-1 (identical to primary, same manifests)
4. Update `k8s/base/configmaps/backend-config.yaml` `DB_HOST` to secondary RDS endpoint
5. ArgoCD syncs within 3 minutes
6. Update `secondary_alb_dns` to new nginx NLB → `terraform apply`

---

## 6. RDS Storage Autoscaling

**`modules/rds/variables.tf`** — new variable:
```hcl
variable "max_allocated_storage" {
  description = "Upper limit for RDS storage autoscaling in GB. 0 = disabled."
  type        = number
  default     = 100
}
```

**`modules/rds/main.tf`** — `aws_db_instance`:
```hcl
allocated_storage     = var.db_allocated_storage     # 25 GB initial
max_allocated_storage = var.max_allocated_storage     # 100 GB ceiling
```

RDS auto-scales storage when free space < 10% of allocated. No downtime. No manual resize.

---

## Files Changed This Session

| File | Type of change |
|---|---|
| `k8s/base/kustomization.yaml` | Removed MySQL entries, added monitoring files |
| `k8s/base/configmaps/backend-config.yaml` | DB_HOST → RDS endpoint placeholder |
| `k8s/base/network-policy/network-policy.yaml` | Backend egress: pod selector → VPC CIDR; removed mysql-policy |
| `k8s/base/backend/rollout.yaml` | Canary steps 10→25→50→100 + analysis references |
| `k8s/base/monitoring/prometheus-rules.yaml` | New — 3 alert rules |
| `k8s/base/monitoring/analysis-template.yaml` | New — AnalysisTemplate for canary error-rate gating |
| `modules/eks-addons/main.tf` | Added Loki helm_release; enabled Alertmanager |
| `modules/eks-addons/outputs.tf` | Added loki_service output |
| `modules/rds/main.tf` | Added max_allocated_storage |
| `modules/rds/variables.tf` | Added max_allocated_storage variable |
| `modules/rds/outputs.tf` | Added rds_instance_arn |
| `main.tf` | Secondary provider; RDS backup replication; ECR replication; Route53 public zone + health check + failover records; max_allocated_storage in RDS module |
| `variables.tf` | Added secondary_region, primary_alb_dns, secondary_alb_dns |
| `outputs.tf` | Added route53_public_zone_id, route53_public_name_servers, loki_service_url |
| `docs/phase-2-implementation.md` | New — technical implementation reference |
| `docs/phase-2-improvements.md` | New — improvements over Phase 1 |

---

## Industry Best Practices Applied

### Terraform
- **Module separation** — each concern (network, EKS, RDS, ECR, security, addons, route53) is a standalone module with typed variables and outputs
- **No hardcoded secrets** — RDS password managed by AWS (`manage_master_user_password = true`); no plaintext anywhere
- **Storage encryption** — RDS `storage_encrypted = true`; ECR `encryption_type = "AES256"`
- **Immutable image tags** — ECR `image_tag_mutability = "IMMUTABLE"`
- **Provider aliasing** — secondary region uses `aws.secondary` alias, not a separate state/workspace
- **Conditional resources** — `count = var.x != "" ? 1 : 0` pattern for optional Route53 records
- **Explicit `depends_on`** — Loki waits for kube-prometheus-stack; EBS CSI policy before addon; ECR before replication
- **Variable documentation** — every variable has description and sensible default

### Kubernetes / GitOps
- **GitOps single source of truth** — ArgoCD `selfHeal + prune`; cluster state always matches git
- **Kustomize overlays** — base + dev/prod overlays; no config duplication
- **Progressive delivery** — Argo Rollouts canary with Prometheus-gated analysis, not `kubectl set image`
- **Automated rollback** — AnalysisTemplate fails rollout on >1% 5xx rate; 2-failure threshold prevents false positives
- **Network policies** — default-deny-all in `bookstore` namespace; only required traffic allowed
- **Pod security** — non-root UID, read-only filesystem, all capabilities dropped, seccomp RuntimeDefault
- **External Secrets Operator** — credentials never in git or ConfigMaps
- **PodDisruptionBudget** — cluster node drain doesn't take down all replicas simultaneously
- **Readiness + liveness probes** — prevents traffic to unready pods; restarts hung containers

### Observability
- **Three pillars** — metrics (Prometheus), logs (Loki + Promtail), dashboards (Grafana)
- **ServiceMonitor CRD** — Prometheus scrape config in git, not manual job config
- **PrometheusRule CRD** — alert definitions in git with `release: kube-prometheus-stack` label
- **Structured alert labels** — severity tagging on every alert for Alertmanager routing

### Multi-Region
- **Active-passive, not active-active** — simpler, safer for a demo; no distributed transaction complexity
- **Managed backup replication** — `aws_db_instance_automated_backups_replication` vs. manual snapshot copies
- **Image replication before DR** — ECR replication runs continuously so secondary region never pulls across regions during an incident
- **Health-check-gated failover** — Route53 only routes to secondary when primary health check fails (3 of 3 checks)
- **Two-phase apply** — first apply gets infra running, second wires DNS after ALB is known; avoids chicken-and-egg

---

## Open Items for Phase 3

| Item | Why |
|---|---|
| S3 backend for Terraform state | Remote state required for team use and CI locking |
| `deletion_protection = true` on RDS | Prevent accidental `terraform destroy` |
| Graceful shutdown in Node.js backend | `process.on('SIGTERM')` to drain in-flight requests |
| Integration tests against real RDS | Vitest unit tests use mock DB — no real schema coverage |
| Secondary EKS cluster (us-east-1) | Completes the active-passive architecture |
| Grafana Loki data source provisioning | Currently manual step after deploy |
