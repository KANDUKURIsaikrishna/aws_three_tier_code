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

## Item 4 — Observability (EC2-based Prometheus + Grafana + Loki) ✅ DONE

**Why:** `kube-prometheus-stack` in EKS (~6 pods, ~950 MB RAM) saturates the single `t3.medium` node even at 900 s timeout. Moving the entire monitoring stack to a dedicated EC2 instance frees ~950 MB RAM and eliminates Helm timeouts — while keeping EKS cluster zero monitoring pods.

**Architecture:**

| Where | Components | How it connects |
|---|---|---|
| EC2 `t3.small` (public subnet, EIP) | Prometheus + Grafana + Loki (Docker Compose) | Static EIP; accessible from internet on 3000/9090; Loki on 3100 from VPC only |
| EKS node launch template | node-exporter (systemd, port 9100) | Prometheus on EC2 scrapes directly via VPC |
| EKS node launch template | Fluent Bit (systemd) | Pushes container logs to Loki on EC2 (port 3100) |
| EC2 Docker Compose | kube-state-metrics | Runs on EC2 with kubeconfig; talks to EKS API via EKS access entry |

**How Prometheus scrapes EKS nodes:**
- A cron job (`update-prom-targets.sh`) runs every 5 minutes and rewrites `/opt/monitoring/prometheus/targets/ne.json` using `aws ec2 describe-instances --filters "Name=tag:eks:cluster-name"`.
- Prometheus uses `file_sd_configs` pointing to that JSON file — hot-reloads targets automatically.
- EKS cluster SG allows inbound port 9100 from monitoring EC2 SG.

**How kube-state-metrics runs on EC2 without being in the cluster:**
- `aws eks update-kubeconfig` generates `/root/.kube/config` at first boot.
- An EKS access entry grants the monitoring EC2 IAM role `AmazonEKSViewPolicy` (read-only K8s API).
- kube-state-metrics runs as a Docker Compose service mounting `/root/.kube`, scrapes the EKS API from outside the cluster.

**Automation built in:**
- Grafana dashboards auto-imported at first boot: Node Exporter Full (1860) + Kubernetes cluster monitoring (315).
- Prometheus alerting rules provisioned: `NodeDown`, `HighCPUUsage`, `HighMemoryUsage`, `PodCrashLooping`, `KubeStateMetricsDown`.
- Grafana admin password fetched from Secrets Manager at boot (no plaintext on disk).

**EKS node launch template (MIME multipart):**
- AL2 managed node groups merge MIME user-data with EKS bootstrap — custom part runs first, then EKS joins the node.
- Installs node-exporter v1.8.2 as systemd service.
- Installs Fluent Bit from official Amazon Linux 2 repo as systemd service.

**Access Grafana:**
```bash
# Get the EIP-based URL from Terraform outputs
terraform output grafana_url          # → http://<EIP>:3000
terraform output prometheus_url       # → http://<EIP>:9090

# Retrieve Grafana admin password
aws secretsmanager get-secret-value \
  --secret-id /bookstore/grafana-admin \
  --region us-west-1 --query SecretString --output text
```

**Also added:**
- `modules/eks-addons/grafana-secret.tf` — Grafana admin password (`random_password`, 24 chars) stored in Secrets Manager at `/bookstore/grafana-admin`
- `backend/app.js` exposes `/metrics` using `prom-client` (`http_requests_total`, `http_request_duration_seconds`, default Node.js metrics)
- `k8s/base/monitoring/servicemonitor.yaml` — scrapes backend `/metrics` every 30s

**Files:** `modules/monitoring-ec2/` (new module: main.tf, variables.tf, outputs.tf, user-data.sh.tftpl), `modules/eks/node-user-data.sh.tftpl` (new), `modules/eks/main.tf`, `modules/eks-addons/observability.tf`, `modules/eks-addons/grafana-secret.tf`, `backend/app.js`, `k8s/base/monitoring/servicemonitor.yaml`, `main.tf`, `outputs.tf`, `variables.tf`

**Effort:** 1 day

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

## Item 7 — EC2 monitoring migration + automation ✅ DONE

**Why:** kube-prometheus-stack timed out even at 900 s due to node resource exhaustion (see `docs/phase-2-troubleshooting.md` TF-006). Zero monitoring pods in EKS + EC2 Docker Compose is the right architecture for a constrained single-node cluster.

**Summary of changes:** See Item 4 above (Observability) for full detail. This item tracks the migration work done after the initial implementation.

**Automation added:**
- `Makefile` — `make apply` (init + import known secrets + apply), `make monitoring-status`, `make monitoring-logs`
- Grafana dashboard auto-import script (`import-grafana-dashboards.sh`) runs as background job on first boot
- Prometheus `rule_files` provisioned with 5 alerting rules

**Commits:** `d0d85cc`

---

## Item 8 — Kubernetes + Terraform security hardening ✅ DONE

**Why:** Audit found 4 real issues across K8s manifests and Terraform security groups.

**Changes:**

| File | Fix |
|---|---|
| `modules/security/main.tf` | Removed `rds_egress` (0.0.0.0/0 all protocols). RDS never initiates outbound connections — the rule was dead code that widened blast radius. |
| `k8s/base/backend/rollout.yaml` | Added resource `requests`/`limits` to the base manifest. Dev overlay had no limits — pods could starve the node. |
| `k8s/overlays/prod/kustomization.yaml` | Changed `op: add` → `op: replace` for resources patch (base now has resources; `add` is semantically incorrect when field exists). |
| `k8s/base/database/mysql-statefulset.yaml` | Added `timeoutSeconds: 5` + `failureThreshold: 3` to both probes. `mysqladmin ping` can exceed the default 1 s timeout under load, causing false liveness kills. |
| `modules/eks-addons/ingress.tf` | Added `controller.podDisruptionBudget.minAvailable: 1` to ingress-nginx Helm chart. |

**What was already correct (not changed):**
- All 3 workloads (frontend, backend, MySQL) had both liveness + readiness probes.
- `readOnlyRootFilesystem: true`, `runAsNonRoot: true`, `seccompProfile: RuntimeDefault`, `capabilities: drop ALL` on all workloads that support it.
- NetworkPolicy, PodDisruptionBudget, HPA all existed.
- RDS: `multi_az`, `backup_retention_period`, `deletion_protection` all set.
- ExternalSecrets: no plaintext secrets in Git.

**Commit:** `f541a00`

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

| # | Item | Status | Commit |
|---|---|---|---|
| 1 | gp3 StorageClass manifest | **DONE** | — |
| 2 | EKS add-ons in Terraform (`modules/eks-addons/`) | **DONE** | — |
| 3 | Kustomize overlays (dev / prod) | **DONE** | — |
| 4 | Observability — EC2-based Prometheus + Grafana + Loki | **DONE** | `0454d90`, `d0d85cc` |
| 5 | Argo Rollouts canary for backend | **DONE** | — |
| 6 | Backend tests (vitest + vi.fn() mock db) | **DONE** | — |
| 7 | EC2 monitoring automation (Makefile, dashboards, alerts) | **DONE** | `d0d85cc` |
| 8 | K8s + Terraform security hardening | **DONE** | `f541a00` |
