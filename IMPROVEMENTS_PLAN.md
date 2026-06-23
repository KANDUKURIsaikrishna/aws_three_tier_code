# Improvements Plan — `improvements` branch

**Scope:** Tech demo / learning reference. NOT production grade.
Single cluster, single region, bare-minimum cost. Multi-region and HA are explicitly out of scope.

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

## Item 1 — gp3 StorageClass as a declarative manifest

**Why:** Currently created imperatively by `eks_bootstrap.py` or `kubectl apply`. Should live in git like every other resource.

**What to do:**
- Create `k8s/storageclass/gp3.yaml`
- Add it to `k8s/kustomization.yaml` resources list
- Remove the `kubectl apply` StorageClass block from `eks_bootstrap.py` Phase 3

**Files:** `k8s/storageclass/gp3.yaml`, `k8s/kustomization.yaml`, `eks_bootstrap.py`

**Effort:** 30 min

---

## Item 2 — EKS add-ons in Terraform (`modules/eks-addons/`)

**Why:** cert-manager, ESO, Nginx Ingress, and ArgoCD are installed by `eks_bootstrap.py`. Bringing them into Terraform makes the cluster reproducible with `terraform apply` alone.

**What to do:**
- Create `modules/eks-addons/main.tf` with `helm_release` resources for:
  - `aws-ebs-csi-driver` (EKS addon, not Helm — use `aws_eks_addon`)
  - `cert-manager` (jetstack/cert-manager)
  - `external-secrets` (external-secrets/external-secrets)
  - `ingress-nginx` (ingress-nginx/ingress-nginx)
  - `argo-cd` (argo/argo-cd)
- Create `modules/eks-addons/variables.tf` (cluster name, OIDC provider ARN, region)
- Wire into `main.tf` after the `eks` module
- Slim down `eks_bootstrap.py` to only: kubeconfig, IRSA role, ClusterIssuer, DB init (things Terraform can't do)

**Minimal Helm values (tech demo — no HA, no redundant replicas):**

```hcl
# cert-manager
set { name = "replicaCount", value = "1" }

# ingress-nginx
set { name = "controller.replicaCount", value = "1" }

# argocd
set { name = "server.replicas", value = "1" }
set { name = "repoServer.replicas", value = "1" }
```

**Files:** `modules/eks-addons/main.tf`, `modules/eks-addons/variables.tf`, `main.tf`, `eks_bootstrap.py`

**Effort:** half day

---

## Item 3 — Kustomize overlays (dev / prod)

**Why:** Right now all environment differences (DB host, replica count, resource limits) require manual edits. Overlays make it declarative.

**What to do — minimal two-overlay structure:**

```
k8s/
  base/                     ← move existing manifests here
    kustomization.yaml
    backend/
    frontend/
    database/
    ingress/
    ...
  overlays/
    dev/
      kustomization.yaml    ← patches: replicas=1, DB_HOST=mysql-service, no resource limits
    prod/
      kustomization.yaml    ← patches: replicas per HPA, DB_HOST=<rds-endpoint>, resource limits
```

**Dev overlay patches:**
- `DB_HOST` ConfigMap → `mysql-service` (in-cluster MySQL)
- No resource requests/limits (saves memory on 1 node)
- HPA disabled (replace with fixed replicas=1)

**Prod overlay patches:**
- `DB_HOST` ConfigMap → RDS endpoint (from `terraform output rds_endpoint`)
- Resource requests: backend 128m CPU / 128Mi RAM, frontend 64m / 64Mi
- HPA enabled

**ArgoCD application.yaml** — change `path: k8s` to `path: k8s/overlays/prod`

**Files:** `k8s/` (restructure), `k8s/argocd/application.yaml`

**Effort:** 2–3 hours

---

## Item 4 — Observability (Prometheus + Grafana only, no Loki)

**Why:** Basic metrics visibility. Loki (log aggregation) is skipped — too heavy for 1 node, and `kubectl logs` is sufficient for a demo.

**What to do:**

Add to `modules/eks-addons/main.tf`:

```hcl
resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  namespace  = "monitoring"
  create_namespace = true

  # Minimal for tech demo — no HA
  set { name = "prometheus.prometheusSpec.replicas",        value = "1" }
  set { name = "alertmanager.enabled",                      value = "false" }
  set { name = "grafana.replicas",                          value = "1" }
  set { name = "grafana.persistence.enabled",               value = "false" }
  set { name = "prometheus.prometheusSpec.retention",       value = "24h" }
  set { name = "prometheus.prometheusSpec.storageSpec",     value = "" }  # no PVC for demo
}
```

Add `prom-client` to the Node.js backend:
- `npm install prom-client`
- Expose `/metrics` endpoint
- Track: `http_requests_total`, `http_request_duration_seconds`, `db_query_duration_seconds`

Add a `k8s/monitoring/servicemonitor.yaml` so Prometheus scrapes the backend.

Access Grafana: `kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80`

**Skipped:** Loki, persistent storage for metrics, AlertManager, PagerDuty

**Files:** `modules/eks-addons/main.tf`, `backend/index.js` (or separate `metrics.js`), `k8s/monitoring/servicemonitor.yaml`

**Effort:** half day

---

## Item 5 — Canary deployments with Argo Rollouts

**Why:** Replace the current rolling `Deployment` with a progressive delivery strategy. If error rate spikes after 10% canary, it auto-rolls back.

**What to do (minimal):**
- Install Argo Rollouts via Helm in `modules/eks-addons/main.tf`
- Convert `k8s/backend/deployment.yaml` → `k8s/backend/rollout.yaml` (kind: Rollout)
- Simple canary strategy: 10% → 50% → 100%, step pause = 30s (auto — no manual approval needed for demo)
- Update CI Stage 4: `kubectl argo rollouts set image` instead of `kustomize edit set image`

**Minimal Rollout spec:**

```yaml
strategy:
  canary:
    steps:
    - setWeight: 10
    - pause: {duration: 30s}
    - setWeight: 50
    - pause: {duration: 30s}
```

**Skip:** Flagger, Prometheus-based automated analysis (too complex for demo), frontend canary

**Files:** `k8s/backend/rollout.yaml` (replaces `deployment.yaml`), `modules/eks-addons/main.tf`, `.github/workflows/ci-cd.yml`

**Effort:** 2 hours

---

## Item 6 — Backend integration tests (Jest + SQLite)

**Why:** No automated test suite means Trivy is the only quality gate. Jest + SQLite gives fast unit-level coverage with no external dependencies.

**What to do:**
- `npm install --save-dev jest supertest better-sqlite3`
- Create `backend/__tests__/books.test.js`:
  - Uses `better-sqlite3` to spin up an in-memory DB
  - Seeds schema from the same SQL as `mysql-init-configmap.yaml`
  - Tests: GET /books, POST /books, GET /books/:id, DELETE /books/:id
- Add `"test": "jest"` to `backend/package.json`
- Wire into CI Stage 1: add a test step before `npm audit`

**Skip:** test containers (Docker-in-Docker in CI is slow), full E2E tests

**Files:** `backend/__tests__/books.test.js`, `backend/package.json`, `.github/workflows/ci-cd.yml`

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

## Work order for tomorrow

1. **Item 1** — gp3 StorageClass manifest (30 min, isolated change)
2. **Item 6** — Backend tests (can do while Terraform runs)
3. **Item 2** — EKS add-ons in Terraform (biggest change, do while fresh)
4. **Item 3** — Kustomize overlays (depends on understanding the current structure)
5. **Item 4** — Observability (add to eks-addons module from Item 2)
6. **Item 5** — Argo Rollouts canary (final touch)
