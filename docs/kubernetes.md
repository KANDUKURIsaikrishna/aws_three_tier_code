# Kubernetes Reference

Bookstore app Kubernetes configuration. Managed by ArgoCD GitOps — never apply manifests manually in production.

---

## Directory Structure

```
k8s/
├── base/                          # shared manifests — no image tags, no replica counts
│   ├── namespace.yaml             # bookstore namespace
│   ├── storageclass/gp3.yaml      # gp3 StorageClass (replaces gp2 default)
│   ├── backend/
│   │   ├── rollout.yaml           # Argo Rollout (canary strategy)
│   │   └── service.yaml           # ClusterIP :3000
│   ├── frontend/
│   │   ├── deployment.yaml        # 2 replicas, Nginx 1.27
│   │   └── service.yaml           # ClusterIP :8080
│   ├── database/
│   │   ├── mysql-statefulset.yaml # MySQL 8.0.39 (dev/local only)
│   │   ├── mysql-service.yaml     # ClusterIP :3306
│   │   └── mysql-init-configmap.yaml  # CREATE DATABASE init script
│   ├── ingress/ingress.yaml       # Nginx ingress (TLS, host rules)
│   ├── configmaps/backend-config.yaml  # DB_PORT, DB_NAME, APP_PORT
│   ├── secrets/external-secret.yaml    # ESO ExternalSecret → db-secret
│   ├── cert-manager/cluster-issuer.yaml  # Let's Encrypt ACME ClusterIssuer
│   ├── network-policy/network-policy.yaml  # deny-all + allow-listed policies
│   ├── pdb/pdb.yaml               # PodDisruptionBudgets (backend + frontend)
│   ├── quota.yaml                 # ResourceQuota (bookstore namespace)
│   └── monitoring/
│       ├── servicemonitor.yaml    # Prometheus ServiceMonitor for backend /metrics
│       ├── prometheus-rules.yaml  # PrometheusRule (HighErrorRate alert)
│       └── analysis-template.yaml # Argo Rollouts AnalysisTemplate (canary gate)
│
├── overlays/
│   ├── dev/kustomization.yaml     # dev: base only, no image pins
│   └── prod/
│       ├── kustomization.yaml     # image pins (000000000000 placeholder, CI overwrites)
│       ├── hpa-backend.yaml       # HPA: 1–5 replicas
│       └── hpa-frontend.yaml      # HPA: 2–3 replicas
│
└── argocd/application.yaml        # ArgoCD Application manifest
```

---

## Namespace Layout

| Namespace | Contents |
|---|---|
| `bookstore` | frontend, backend, ESO ExternalSecret, db-secret, configmap, ingress, NetworkPolicy, PDB, ResourceQuota |
| `monitoring` | Prometheus, Grafana, Alertmanager, Loki, Promtail, ServiceMonitor |
| `argocd` | ArgoCD server, repo-server, application-controller |
| `ingress-nginx` | nginx-ingress controller, NLB service |
| `cert-manager` | cert-manager controller, ClusterIssuer, Certificate |
| `argo-rollouts` | Argo Rollouts controller |
| `external-secrets` | ESO controller, ClusterSecretStore |

---

## Kustomize Overlays

Base manifests contain no image tags and no replica counts. Overlays add environment-specific configuration.

**Prod overlay** patches:
- Image tags via `kustomize edit set image` (CI-managed, `secrets.AWS_ACCOUNT_ID` source)
- Backend resource limits via strategic merge patch
- ClusterIssuer ACME email via JSON6902 patch
- HPA for backend (1–5) and frontend (2–3)

ECR registry placeholder in `prod/kustomization.yaml`:
```yaml
images:
- name: bookstore-backend
  newName: 000000000000.dkr.ecr.us-west-1.amazonaws.com/bookstore-backend
  newTag: latest
```
CI deploy stage overwrites `000000000000` with real account ID from `secrets.AWS_ACCOUNT_ID` on every push to `main`.

---

## Applications

### Frontend (Deployment)

- **Image:** `bookstore-frontend:<sha8>` — Nginx 1.27-alpine, multi-stage build (React → static files)
- **Replicas:** 2 (base), HPA 2–3 (prod overlay)
- **Port:** 8080 (non-root Nginx)
- **Probe:** `GET /health :8080`
- **Writable volumes:** `/tmp`, `/var/cache/nginx`, `/var/run` (emptyDir — required by Nginx)

Security context:
```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 101       # nginx user
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["ALL"]
  seccompProfile:
    type: RuntimeDefault
```

### Backend (Argo Rollout)

- **Kind:** `argoproj.io/v1alpha1 Rollout` — NOT a standard Deployment
- **Image:** `bookstore-backend:<sha8>` — Node.js 18 Alpine, prod deps only
- **Replicas:** 1 (base), HPA 1–5 (prod overlay)
- **Port:** 3000
- **Probes:** `GET /health :3000` (readiness: 10s delay, 5s period; liveness: 30s delay, 15s period)
- **Writable volumes:** `/tmp` (emptyDir only)

Security context:
```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1001
  runAsGroup: 1001
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["ALL"]
  seccompProfile:
    type: RuntimeDefault
```

Environment variables from two sources:
```yaml
# From db-secret (ESO-managed, pulled from Secrets Manager)
DB_HOST, DB_USERNAME, DB_PASSWORD

# From backend-config ConfigMap
DB_PORT, DB_NAME, APP_PORT
```

### Dev MySQL (StatefulSet — dev only)

- **Image:** `mysql:8.0.39` (pinned patch version)
- **PVC:** 10Gi gp3 via `aws-ebs-csi-driver`
- **Probes:** `mysqladmin ping` (readiness: 20s delay, liveness: 60s delay)
- **Caps:** drop ALL + re-add `CHOWN`, `SETUID`, `SETGID`, `DAC_OVERRIDE` (MySQL init requirement)
- **Pod fsGroup:** `999` (mysql user owns data volume)

In production `DB_HOST` points to RDS. MySQL StatefulSet exists only for local dev and CI integration testing.

---

## Canary Rollout (Argo Rollouts)

Backend uses progressive delivery instead of a rolling update:

```
New image deployed
│
├── Step 1: setWeight 10%        10% of requests → canary pod
├── Step 2: analysis             AnalysisTemplate error-rate check
├── Step 3: pause 30s
├── Step 4: setWeight 25%
├── Step 5: pause 30s
├── Step 6: setWeight 50%
├── Step 7: analysis             second error-rate check
└── Step 8: pause 60s → 100%    full promotion
```

**On failure:** automatic abort → stable image at 100%  
**Manual abort:** `kubectl argo rollouts abort backend -n bookstore`  
**Manual promote:** `kubectl argo rollouts promote backend -n bookstore`

Traffic splitting uses nginx-ingress `canary-weight` annotation — no service mesh required.

### AnalysisTemplate

```yaml
# k8s/base/monitoring/analysis-template.yaml
metrics:
- name: error-rate
  interval: 30s
  failureLimit: 2        # 2 consecutive failures → abort rollout
  successCondition: result[0] < 0.01   # < 1% 5xx rate
  provider:
    prometheus:
      address: http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090
      query: |
        (
          sum(rate(nginx_ingress_controller_requests{status=~"5..",ingress="bookstore-ingress"}[2m]))
          or vector(0)    ← prevents division by zero on zero traffic
        )
        /
        (
          sum(rate(nginx_ingress_controller_requests{ingress="bookstore-ingress"}[2m]))
          or vector(1)
        )
```

---

## ArgoCD Application

Deployed once manually: `kubectl apply -f k8s/argocd/application.yaml`

```yaml
spec:
  source:
    repoURL: https://github.com/KANDUKURIsaikrishna/aws_three_tier_code.git
    targetRevision: main
    path: k8s/overlays/prod     # ArgoCD runs `kustomize build` here
  destination:
    server: https://kubernetes.default.svc
    namespace: bookstore
  syncPolicy:
    automated:
      prune: true        # deletes resources removed from git
      selfHeal: true     # reverts manual kubectl changes
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
    retry:
      limit: 5
      backoff: { duration: 5s, factor: 2, maxDuration: 3m }
```

ArgoCD polls every 3 minutes. After CI commits updated image tags, cluster reconciles automatically within ~3 minutes.

**ArgoCD UI access:**
```bash
kubectl get secret -n argocd argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Open https://localhost:8080 — login: admin / <password above>
```

---

## Secrets — External Secrets Operator

No credentials in git. ESO pulls from AWS Secrets Manager via IRSA.

```
Secrets Manager /bookstore/db-credentials
  { DB_USERNAME, DB_PASSWORD, DB_HOST }
          ↓ (IRSA — ESO ServiceAccount assumes IAM role)
ExternalSecret (k8s/base/secrets/external-secret.yaml)
  refreshInterval: 1h
          ↓
Kubernetes Secret "db-secret" in bookstore namespace
          ↓
backend pod env vars: DB_HOST, DB_USERNAME, DB_PASSWORD
```

ESO refreshes every hour. No pod restart required for credential rotation.

**Verify ESO sync:**
```bash
kubectl describe externalsecret -n bookstore db-secret
```

---

## Network Policies

All traffic in `bookstore` namespace is denied by default. Only explicitly allowed flows pass.

```
default-deny-all  →  blocks all ingress + egress for every pod

frontend-policy:
  ingress: from ingress-nginx namespace :8080
  egress:  to backend pods :3000
           to DNS :53 UDP/TCP

backend-policy:
  ingress: from frontend pods :3000
           from ingress-nginx namespace :3000
  egress:  to 170.20.0.0/16 :3306  (RDS in VPC CIDR)
           to DNS :53 UDP/TCP
```

Backend cannot reach the internet. Frontend cannot reach RDS. All inter-pod traffic beyond these rules is blocked.

---

## Ingress & TLS

```
Internet :443
  → NLB (provisioned by ingress-nginx via LoadBalancer service)
  → nginx-ingress controller pod
  → routes by Host header:
      b17facebook.xyz        → frontend:8080
      api.b17facebook.xyz    → backend:3000
  → TLS termination at nginx
     cert-manager issues cert from Let's Encrypt (DNS: ACME HTTP-01)
     auto-renewed 30 days before expiry
```

ClusterIssuer ACME email: `kandukurisaikrishna778@gmail.com` (patched by prod overlay).  
Certificate stored as Kubernetes Secret in `bookstore` namespace.

---

## Observability

### Prometheus Scraping

`ServiceMonitor` CRD auto-discovers backend pods via label selector. Backend exposes `/metrics` (prom-client):
```
http_requests_total{method, route, status}
http_request_duration_seconds{method, route, status}
```

### Alerting

`PrometheusRule` fires `HighErrorRate` when 5xx rate > 1% for 2 continuous minutes → sends to Alertmanager.

### Grafana

```bash
# Retrieve auto-generated password (24 chars) from Secrets Manager
GRAFANA_PASS=$(aws secretsmanager get-secret-value \
  --secret-id /bookstore/grafana-admin \
  --region us-west-1 \
  --query SecretString --output text)
kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80
# Open http://localhost:3000 — login: admin / <password above>
```

Loki datasource pre-provisioned — query logs alongside metrics in same panel using LogQL.

---

## HPA (Prod Overlay)

| Workload | Min | Max | CPU target | Memory target |
|---|---|---|---|---|
| backend | 1 | 5 | 70% | — |
| frontend | 2 | 3 | 70% | — |

---

## PodDisruptionBudget

```yaml
# backend-pdb + frontend-pdb
spec:
  minAvailable: 1
```

Prevents draining a node from taking down all pods. Ensures at least 1 replica stays available during cluster upgrades.

---

## ResourceQuota (bookstore namespace)

```yaml
hard:
  requests.cpu:    "2"
  limits.cpu:      "4"
  requests.memory: 2Gi
  limits.memory:   4Gi
  pods:            "20"
```

---

## StorageClass

```yaml
# k8s/base/storageclass/gp3.yaml
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  encrypted: "true"
allowVolumeExpansion: true
```

Replaces the default `gp2` StorageClass. Used by Prometheus TSDB PVC and MySQL PVC (dev).

---

## Common kubectl Commands

```bash
# All pods in bookstore namespace
kubectl get pods -n bookstore

# Backend logs
kubectl logs -n bookstore -l app=backend --tail=50

# ESO sync status
kubectl describe externalsecret -n bookstore db-secret

# Canary rollout status
kubectl argo rollouts get rollout backend -n bookstore --watch

# TLS certificate status
kubectl get certificate -n bookstore
kubectl describe certificate -n bookstore

# Ingress (check for address)
kubectl get ingress -n bookstore

# Prometheus targets
kubectl port-forward svc/kube-prometheus-stack-prometheus -n monitoring 9090:9090
# Open http://localhost:9090/targets
```

---

## Troubleshooting

| Symptom | Check |
|---|---|
| Backend `CrashLoopBackOff` | `kubectl logs -n bookstore -l app=backend` — likely `DB_HOST` not set or RDS unreachable |
| ESO secret not created | `kubectl describe externalsecret -n bookstore db-secret` — IRSA role or secret path wrong |
| TLS cert pending | `kubectl describe certificate -n bookstore` — verify ClusterIssuer email and NS delegation |
| ArgoCD `OutOfSync` | Check repo URL in `k8s/argocd/application.yaml` matches actual repo |
| Canary stuck at 10% | `kubectl argo rollouts get rollout backend -n bookstore` — check analysis failure reason |
| Nginx 504 | Backend not ready — check readiness probe and RDS connectivity |
| NetworkPolicy blocking traffic | `kubectl describe networkpolicy -n bookstore` — check allowed selectors |
