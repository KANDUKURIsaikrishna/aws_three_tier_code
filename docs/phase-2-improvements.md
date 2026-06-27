# Phase 2 — Improvements Over Phase 1

## Summary

Phase 1 was a functional but basic 3-tier deploy: EKS + RDS + ECR, with raw Kubernetes manifests and no deployment safety. Phase 2 adds operational maturity: progressive delivery, GitOps automation, environment parity, observability, and security hardening.

---

## 1. Deployment Safety: Canary via Argo Rollouts

**Phase 1:** Standard `Deployment` — immediate replace. Bad image = full outage.

**Phase 2:** `Rollout` resource with canary steps (10% → 30s → 50% → 30s → 100%). Failed readiness probe halts rollout. Manual abort via `kubectl argo rollouts abort`.

**Why better:** New image defect affects 10% of traffic max. Catch errors before full blast radius.

---

## 2. Database: RDS Only — No In-Cluster MySQL

**Phase 1:** MySQL StatefulSet inside cluster with PVC (gp3 EBS). Dev/prod share same in-cluster DB. PV/PVC complexity, no backup, no HA.

**Phase 2:** All environments use AWS RDS. No StatefulSet, no PVC for DB. `DB_HOST` in configmap points to RDS endpoint.

- RDS handles backups, multi-AZ HA, point-in-time recovery
- No PV/PVC lifecycle to manage
- Dev and prod both hit RDS (separate instances or same demo instance)

**Why better:** Managed DB. No data loss risk from PVC deletion. No in-cluster DB eating node memory.

---

## 3. GitOps: ArgoCD Replaces Manual kubectl

**Phase 1:** Manual `kubectl apply` or ad-hoc `kubectl set image`. Cluster state drifts from repo.

**Phase 2:** ArgoCD as single source of truth. `selfHeal: true` reverts manual changes. `prune: true` removes orphaned resources. Every cluster state change traceable to a git commit.

**Why better:** No config drift. Rollback = `git revert`.

---

## 4. Kustomize Overlays: Environment Parity

**Phase 1:** Single manifest set. Dev and prod share config. Resource limits hardcoded or absent.

**Phase 2:** Base + overlays. Dev: single replica, no limits. Prod: ECR image pins, resource requests/limits, HPA.

**Why better:** Same base YAML, no duplication. Dev is lightweight. Prod is hardened.

---

## 5. Minimal Cluster Sizing (Demo-First)

**Phase 1:** Oversized defaults for dev demo. Unnecessary cost.

**Phase 2:** Explicit minimal sizing:

| Resource | Phase 1 | Phase 2 |
|---|---|---|
| EKS desired nodes | 2 | 1 |
| EKS max nodes | 4 | 2 |
| Backend HPA max | 10 | 5 |
| Frontend HPA max | 5 | 3 |

**Why better:** Demo needs 1 node. Scale only under real load.

---

## 6. Horizontal Pod Autoscaling

**Phase 1:** Fixed replica count. No scaling under load.

**Phase 2:** HPA on both frontend and backend in prod overlay. Scale out on CPU/memory. Scale back in when idle.

**Why better:** Cost-efficient + handles spikes without manual intervention.

---

## 7. Observability: Prometheus + Grafana

**Phase 1:** No metrics. Blind to app behavior.

**Phase 2:** Prometheus scrapes backend `/metrics` (prom-client). Grafana dashboards for request rate, latency, error rate. `ServiceMonitor` CRD wires scrape targets automatically.

**Why better:** Know what's happening before users report it.

---

## 8. Storage: gp3 for Prometheus Only

**Phase 1:** Default gp2. In-cluster MySQL PVC consuming EBS storage.

**Phase 2:** gp3 StorageClass (20% cheaper, 3000 IOPS baseline). Used only by Prometheus TSDB — no database PVCs.

**Why better:** Cheaper storage. PVCs only where unavoidable (metrics retention).

---

## 9. Secrets: ESO Replaces Manual Kubernetes Secrets

**Phase 1:** DB credentials as manually-created Kubernetes Secrets. Risk of stale creds or leaking to git.

**Phase 2:** External Secrets Operator pulls from AWS Secrets Manager. Creds never touch git. Auto-rotation on configurable interval. IAM-gated access.

**Why better:** Zero manual secret management. Credentials lifecycle managed by AWS.

---

## 10. Pod Security Hardening

**Phase 1:** Default pod security. Root-capable containers.

**Phase 2:** Non-root (UID 1001), read-only root filesystem, all capabilities dropped, seccomp `RuntimeDefault`, `/tmp` only writable via emptyDir.

**Why better:** Container escape has minimal blast radius. Passes CIS Kubernetes benchmark.

---

## 11. TLS: cert-manager + Let's Encrypt

**Phase 1:** HTTP only or manually managed certs.

**Phase 2:** cert-manager auto-provisions and renews TLS. Nginx Ingress enforces HTTPS redirect.

**Why better:** Zero cert management overhead. Auto-renewal prevents expiry incidents.

---

## What's Next: Phase 3 Targets

| Item | Reason |
|---|---|
| Multi-region infra (us-west-1 + us-east-1) | HA + latency routing |
| RDS cross-region read replica | Regional failover |
| S3 backend for Terraform state | Team collaboration, no local state |
| RDS `deletion_protection = true` | Prevent accidental destroy |
| Graceful shutdown in backend | No dropped requests on pod termination |
| Integration tests against real RDS | Real DB parity |
