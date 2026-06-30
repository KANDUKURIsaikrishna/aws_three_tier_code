# Improvements Plan — `improvements` branch

**Scope:** Tech demo / learning reference. NOT production grade.
Single cluster, single region, bare-minimum cost. Multi-region and HA are explicitly out of scope.

**Status:** All 6 items are fully implemented on the `improvements` branch.

---

## Sizing baseline (already applied on this branch)

| Resource | Before | After (this branch) |
|---|---|---|
| Node group desired | 2 | **1** |
| Node group max | 4 | **2** |
| Instance type | t3.medium | t3.medium (keep — smallest that fits all add-ons) |
| Backend HPA min/max | 2 / 10 | **1 / 5** |
| Frontend HPA min/max | 2 / 5 | **1 / 3** |

At rest: 1 node, 1 pod per service. Under load: HPA adds pods, CA adds a second node. Cluster stays at ~$30/month idle (us-west-1 on-demand).

---

## Item 1 — gp3 StorageClass as a declarative manifest ✅ DONE

**Why:** Currently created imperatively by `eks_bootstrap.py` or `kubectl apply`. Should live in git like every other resource.

**What was done:**
- Created `k8s/base/storageclass/gp3.yaml`
- Added it to `k8s/base/kustomization.yaml` resources list
- Removed the `kubectl apply` StorageClass block from `eks_bootstrap.py`

**Files:** `k8s/base/storageclass/gp3.yaml`, `k8s/base/kustomization.yaml`, `eks_bootstrap.py`

**Effort:** 30 min

---

## Item 2 — EKS add-ons in Terraform (`modules/eks-addons/`) ✅ DONE

**Why:** cert-manager, ESO, Nginx Ingress, and ArgoCD are installed by `eks_bootstrap.py`. Bringing them into Terraform makes the cluster reproducible with `terraform apply` alone.

**What was done:**
- Created `modules/eks-addons/main.tf` with `helm_release` resources for:
  - `aws-ebs-csi-driver` (EKS addon — `aws_eks_addon`, not Helm)
  - `cert-manager` (jetstack/cert-manager v1.14.4)
  - `external-secrets` (external-secrets/external-secrets)
  - `ingress-nginx` (ingress-nginx/ingress-nginx v4.9.1)
  - `argo-cd` (argo/argo-cd)
  - `kube-prometheus-stack` (prometheus-community/kube-prometheus-stack)
  - `argo-rollouts` (argo/argo-rollouts)
- Created `modules/eks-addons/variables.tf` (cluster name, OIDC provider ARN, region)
- Added `provider "helm"` (exec auth via `aws eks get-token`) and `module "eks_addons"` to root `main.tf`
- Slimmed down `eks_bootstrap.py` from 10 phases to 8 phases (removed EBS CSI install, Helm repo add/install, ArgoCD install — all handled by Terraform)

**Minimal Helm values (tech demo — no HA, no redundant replicas):**

```hcl
# cert-manager
set { name = "replicaCount", value = "1" }

# ingress-nginx
set { name = "controller.replicaCount", value = "1" }

# argocd
set { name = "server.replicas", value = "1" }
set { name = "repoServer.replicas", value = "1" }

# kube-prometheus-stack
set { name = "prometheus.prometheusSpec.replicas",        value = "1" }
set { name = "alertmanager.enabled",                      value = "true" }
set { name = "alertmanager.alertmanagerSpec.replicas",    value = "1" }
set { name = "grafana.replicas",                          value = "1" }
set { name = "prometheus.prometheusSpec.retention",       value = "24h" }
# grafana admin password injected via set_sensitive from grafana-secret.tf

# argo-rollouts
set { name = "controller.replicas", value = "1" }
```

**Files:** `modules/eks-addons/main.tf`, `modules/eks-addons/cert-manager.tf`, `modules/eks-addons/ebs-csi.tf`, `modules/eks-addons/external-secrets.tf`, `modules/eks-addons/ingress.tf`, `modules/eks-addons/gitops.tf`, `modules/eks-addons/observability.tf`, `modules/eks-addons/grafana-secret.tf`, `modules/eks-addons/variables.tf`, `main.tf`, `eks_bootstrap.py`

**Effort:** half day

---

## Item 3 — Kustomize overlays (dev / prod) ✅ DONE

**Why:** Right now all environment differences (DB host, replica count, resource limits) require manual edits. Overlays make it declarative.

**What was done — two-overlay structure:**

```
k8s/
  base/                              ← all shared resources, no image tags, no HPAs
    kustomization.yaml
    backend/
      rollout.yaml                   ← Argo Rollout (replaces deployment.yaml)
      service.yaml
    frontend/
      deployment.yaml
      service.yaml
    database/
    configmaps/
    secrets/
    ingress/
    network-policy/
    pdb/
    storageclass/
    namespace.yaml
    monitoring/
      servicemonitor.yaml
  overlays/
    dev/
      kustomization.yaml             ← patches replicas=1 on Rollout + Deployment
    prod/
      kustomization.yaml             ← image tags managed by CI; backend resource limits patch
      hpa-backend.yaml               ← targets argoproj.io/v1alpha1 Rollout, min 1 max 5
      hpa-frontend.yaml              ← targets apps/v1 Deployment, min 1 max 3
  argocd/
    application.yaml                 ← path changed: k8s → k8s/overlays/prod
```

**ArgoCD application.yaml** path changed from `k8s` to `k8s/overlays/prod`.

**CI/CD Stage 4** changed from `cd k8s` to `cd k8s/overlays/prod`; commits `k8s/overlays/prod/kustomization.yaml`.

**configure.py** paths updated:
- `k8s/ingress/ingress.yaml` → `k8s/base/ingress/ingress.yaml`
- `k8s/kustomization.yaml` → `k8s/overlays/prod/kustomization.yaml`

**Files:** `k8s/` (restructured), `k8s/argocd/application.yaml`, `.github/workflows/ci-cd.yml`, `scripts/configure.py`

**Effort:** 2–3 hours

---

## Item 4 — Observability (Prometheus + Grafana only, no Loki) ✅ DONE

**Why:** Basic metrics visibility. Loki (log aggregation) is skipped — too heavy for 1 node, and `kubectl logs` is sufficient for a demo.

**What was done:**

Added to `modules/eks-addons/observability.tf`:

```hcl
resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  namespace  = "monitoring"
  create_namespace = true

  set { name = "prometheus.prometheusSpec.replicas",  value = "1" }
  set { name = "alertmanager.enabled",                value = "true" }
  set { name = "alertmanager.alertmanagerSpec.replicas", value = "1" }
  set { name = "grafana.replicas",                    value = "1" }
  set { name = "grafana.persistence.enabled",         value = "false" }
  set { name = "prometheus.prometheusSpec.retention", value = "24h" }
  set_sensitive { name = "grafana.adminPassword",     value = random_password.grafana_admin.result }
}

resource "helm_release" "loki" {
  name       = "loki"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki-stack"
  namespace  = "monitoring"
  set { name = "loki.persistence.enabled", value = "false" }
  set { name = "promtail.enabled",         value = "true" }
  set { name = "grafana.enabled",          value = "false" }
}
```

Also added:
- `modules/eks-addons/grafana-secret.tf` — Grafana admin password (`random_password`, 24 chars, no specials) stored in Secrets Manager at `/bookstore/grafana-admin`
- Grafana auto-configured with Loki as an additional data source (no manual setup)
- Prometheus storage: ephemeral (no PVC), 24h retention — sufficient for demo

Added `prom-client` to the Node.js backend:
- `backend/app.js` exposes `/metrics` endpoint using `prom-client`
- Tracks: `http_requests_total` (Counter) and `http_request_duration_seconds` (Histogram) with method/route/status labels
- Default Node.js metrics also collected via `collectDefaultMetrics()`

Added `k8s/base/monitoring/servicemonitor.yaml` so Prometheus scrapes the backend automatically.

Access Grafana:
```bash
GRAFANA_PASS=$(aws secretsmanager get-secret-value --secret-id /bookstore/grafana-admin \
  --region us-west-1 --query SecretString --output text)
kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80
# Open http://localhost:3000 — login: admin / <password above>
```

**Skipped:** persistent storage for metrics (24h ephemeral sufficient for demo), PagerDuty integration

**Files:** `modules/eks-addons/observability.tf`, `modules/eks-addons/grafana-secret.tf`, `backend/app.js`, `k8s/base/monitoring/servicemonitor.yaml`

**Effort:** half day

---

## Item 5 — Canary deployments with Argo Rollouts ✅ DONE

**Why:** Replace the current rolling `Deployment` with a progressive delivery strategy. If error rate spikes after 10% canary, it auto-rolls back.

**What was done:**
- Installed Argo Rollouts via Helm in `modules/eks-addons/main.tf`
- Converted `k8s/backend/deployment.yaml` → `k8s/base/backend/rollout.yaml` (kind: Rollout)
- Canary strategy: 10% → 50% → 100%, step pause = 30s (auto — no manual approval needed for demo)
- HPA in `k8s/overlays/prod/hpa-backend.yaml` targets `argoproj.io/v1alpha1 / Rollout` (not `Deployment`)
- Dev overlay patches replicas=1 on the Rollout directly

**Rollout spec:**

```yaml
strategy:
  canary:
    analysis:
      templates:
      - templateName: error-rate
      startingStep: 1
    steps:
    - setWeight: 10
    - analysis:
        templates:
        - templateName: error-rate
    - pause: {duration: 30s}
    - setWeight: 25
    - pause: {duration: 30s}
    - setWeight: 50
    - analysis:
        templates:
        - templateName: error-rate
    - pause: {duration: 60s}
```

AnalysisTemplate (`k8s/base/monitoring/analysis-template.yaml`) queries nginx 5xx rate via Prometheus every 30s. Fails rollout if error rate ≥ 1% (`result[0] < 0.01`, `failureLimit: 2`). Auto-aborts to stable on 2 consecutive failures.

**Skipped:** Flagger, frontend canary

**Files:** `k8s/base/backend/rollout.yaml` (replaces `deployment.yaml`), `modules/eks-addons/main.tf`, `k8s/overlays/prod/hpa-backend.yaml`

**Effort:** 2 hours

---

## Item 6 — Backend integration tests (vitest + mock db) ✅ DONE

**Why:** No automated test suite means Trivy is the only quality gate. Tests give fast unit-level coverage with no external dependencies.

**What was done:**
- Backend split into `backend/app.js` (Express app factory `export function createApp(db)`) and `backend/index.js` (creates real MySQL connection, calls `createApp(db)`, starts server)
- `backend/__tests__/books.test.js` — 6 vitest tests, `vi.fn()` mock db, no real DB needed
- Tests cover: `GET /`, `GET /books` (list + empty), `POST /books`, `DELETE /books/:id`, `PUT /books/:id`
- `npm test` runs vitest
- Wired into CI Stage 1: `npm test` runs before `npm audit`; audit uses `--omit=dev`
- CI pipeline triggers on push/PR to both `main` and `improvements` branches

**Skipped:** test containers (Docker-in-Docker in CI is slow), full E2E tests, SQLite (switched to vi.fn() mock — simpler, zero native deps)

**Files:** `backend/app.js`, `backend/index.js`, `backend/__tests__/books.test.js`, `backend/package.json`, `.github/workflows/ci-cd.yml`

**Effort:** 2–3 hours

---

## Skipped items (explicitly out of scope for this demo)

| Item | Reason skipped |
|---|---|
| Multi-region active-passive failover | Overkill for a demo — doubles cost and complexity |
| RDS cross-region read replicas | Part of multi-region — skipped |
| Multiple clusters per region | Explicitly excluded |
| Loki log aggregation | Too heavy for 1-node demo; `kubectl logs` suffices |
| AlertManager / PagerDuty | Not needed for a demo |
| Service mesh (Istio / App Mesh) | Way too heavy for this scope |
| API Gateway | Not needed for a demo |
| Helm chart (instead of Kustomize) | Kustomize overlays cover the need without full chart authoring |

---

## Work order — completed

| # | Item | Status |
|---|---|---|
| 1 | gp3 StorageClass manifest | **DONE** |
| 2 | EKS add-ons in Terraform (`modules/eks-addons/`) | **DONE** |
| 3 | Kustomize overlays (dev / prod) | **DONE** |
| 4 | Observability (Prometheus + Grafana, backend `/metrics`) | **DONE** |
| 5 | Argo Rollouts canary for backend | **DONE** |
| 6 | Backend tests (vitest + vi.fn() mock db) | **DONE** |
