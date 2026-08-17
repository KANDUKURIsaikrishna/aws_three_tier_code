# Kubernetes

What's actually deployed, how the manifests are organized, and how GitOps wires it together.

## Two Kustomize trees, on purpose

```
k8s/
  base/                    ← OLD monolith: frontend + backend, namespace "bookstore"
  overlays/
    dev/
    prod/
  argocd/
    application.yaml         ← manages k8s/overlays/prod (the monolith)
    applicationset-microservices.yaml  ← manages k8s/services/*/overlays/prod

  services/
    catalog-service/        ← namespace "catalog"
      base/
      overlays/prod/
    user-service/           ← namespace "user"
      base/
      overlays/prod/
    order-service/          ← namespace "order"
      base/
      overlays/prod/
    notification-service/   ← namespace "notification"
      base/
      overlays/prod/
    api-gateway/             ← namespace "gateway"
      base/
      overlays/prod/
```

These are deliberately separate. Each microservice is not folded into `k8s/base` because it's a different namespace, different lifecycle, different ArgoCD-managed object — mixing them would make the old-backend removal (the still-paused final task of the api-gateway plan) much messier than swapping one `targetRevision`/one `Application`. All 5 service directories now exist and follow the same layout; `catalog-service` below is the reference example, with per-service differences called out where they matter (`api-gateway` in particular has no DB schema and owns the public `Ingress`).

## `k8s/base/` — the monolith

Resources, in the order `kustomization.yaml` lists them:

| File | What |
|---|---|
| `storageclass/gp3.yaml` | Default gp3 StorageClass |
| `namespace.yaml` | `bookstore` namespace, `pod-security.kubernetes.io/enforce: restricted` |
| `limitrange.yaml` | Per-container default CPU/memory request/limit backstop |
| `secrets/external-secret.yaml` | The cluster-wide `ClusterSecretStore` (every namespace's own `ExternalSecret` references this by name) |
| `frontend/deployment.yaml`, `frontend/service.yaml` | plain Deployment (2 replicas) + Service — the only workload left in this namespace, now that the old monolith backend is fully deleted (OBS-046) |
| `ingress/ingress.yaml` | ALB Ingress for `bookstore.<domain>` — TLS via an ACM cert the AWS Load Balancer Controller auto-discovers, not cert-manager (removed alongside ingress-nginx, OBS-057) |
| `network-policy/network-policy.yaml` | default-deny + frontend allow rule (ingress from the ALB, by VPC CIDR — see the file's own comment for why `ipBlock`, not `namespaceSelector`) |
| `pdb/pdb.yaml` | PodDisruptionBudget for `frontend` |
| `quota.yaml` | namespace ResourceQuota |
| `monitoring/servicemonitor.yaml`, `monitoring/prometheus-rules.yaml` | CRD manifests — **inert**, see below |

`cert-manager/cluster-issuer.yaml`, `configmaps/backend-config.yaml`, `backend/rollout.yaml`, `backend/service.yaml`, and `monitoring/analysis-template.yaml` all used to exist here and are now gone — the first alongside cert-manager itself (OBS-057), the rest alongside the old monolith backend (OBS-046). If you're reading an older version of this table, or a stale cached doc, those five rows no longer describe anything real.

`k8s/base/database/` (`mysql-statefulset.yaml`, `mysql-service.yaml`, `mysql-init-configmap.yaml`) — dead files from an earlier in-cluster-MySQL design, never referenced by `kustomization.yaml` — were deleted 2026-08-14. RDS is, and has always been in the live deployment, the real database.

### Why the monitoring CRD manifests do nothing

`servicemonitor.yaml` and `prometheus-rules.yaml` are `monitoring.coreos.com/v1` CRDs (`ServiceMonitor`, `PrometheusRule`) with `release: kube-prometheus-stack` labels — the convention the Prometheus Operator uses to auto-discover them. **The Prometheus Operator is not installed in this cluster.** Prometheus runs on a standalone EC2 instance via Docker Compose (see [`ARCHITECTURE.md`](ARCHITECTURE.md#why-monitoring-runs-on-ec2-not-in-the-cluster)) and scrapes via static configs + a cron-refreshed `file_sd_configs` target file, not via these CRDs. `analysis-template.yaml` (an Argo Rollouts `AnalysisTemplate`) is the one exception that does something — Argo Rollouts queries the EC2 Prometheus directly over HTTP during canary analysis steps, using a PromQL query, independent of the CRD-discovery mechanism.

### The backend Rollout, not a Deployment

`k8s/base/backend/rollout.yaml` is an `argoproj.io/v1alpha1 Rollout`, Argo Rollouts' drop-in replacement for `Deployment` that adds progressive delivery:

```yaml
strategy:
  canary:
    steps:
    - setWeight: 10
    - analysis: { templates: [{ templateName: error-rate }] }
    - pause: { duration: 30s }
    - setWeight: 25
    - pause: { duration: 30s }
    - setWeight: 50
    - analysis: { templates: [{ templateName: error-rate }] }
    - pause: { duration: 60s }
```

10% → analyze error rate → 30s pause → 25% → 30s pause → 50% → analyze again → 60s pause → 100%. If the `error-rate` `AnalysisTemplate`'s PromQL query breaches its threshold at either analysis step, Argo Rollouts automatically aborts and rolls back — no manual intervention.

Security posture on every container in this repo (not just this one): `runAsNonRoot`, fixed non-root uid/gid (1001), `seccompProfile: RuntimeDefault`, `allowPrivilegeEscalation: false`, all Linux capabilities dropped, `readOnlyRootFilesystem: true` with an `emptyDir` mounted at `/tmp` for anything that needs to write.

## `k8s/overlays/`

`prod/kustomization.yaml`:
- Bases `../../base`, adds `hpa-backend.yaml` + `hpa-frontend.yaml` (HPA isn't in base — dev doesn't need autoscaling)
- Patches the backend `Rollout`'s resources up (128m/128Mi requests → 500m/256Mi limits, vs. base's 50m/64Mi → 250m/128Mi)
- Patches the `ClusterIssuer`'s ACME email
- **Image tags are placeholders** (`newName: 000000000000.dkr.ecr.us-west-1.amazonaws.com/bookstore-backend`, `newTag: latest`) — CI's `deploy` job overwrites the account ID and tag on every push to `main` via `kustomize edit set image`. If you're deploying manually without CI, replace `000000000000` with your real account ID first.

`dev/kustomization.yaml` is base-only — no HPA, no resource bumps.

## ArgoCD

Two GitOps entry points:

**`k8s/argocd/application.yaml`** — manages the monolith. Points at `k8s/overlays/prod`, `targetRevision: main`, auto-sync every 3 minutes, `prune: true` + `selfHeal: true` (any manual `kubectl` change to a resource it owns gets reverted on the next reconcile).

**`k8s/argocd/applicationset-microservices.yaml`** — manages the new services. Uses a `list` generator instead of one `Application` per service:

```yaml
generators:
  - list:
      elements:
        - service: catalog-service
          namespace: catalog
        - service: user-service
          namespace: user
        - service: notification-service
          namespace: notification
        - service: order-service
          namespace: order
        - service: api-gateway
          namespace: gateway
template:
  spec:
    source:
      path: 'k8s/services/{{service}}/overlays/prod'
    destination:
      namespace: '{{namespace}}'
```

All 5 services are now in `elements` — adding a 6th later is still just a one-line addition, no new YAML file. **`targetRevision` is currently pinned to `observability`**, not `main`, since this whole platform is being built on that branch — there's a comment in the file as a reminder to switch it once the work merges, but nothing enforces that automatically. Don't assume it self-corrects.

**Both are Terraform-managed, not manual `kubectl apply`.** ArgoCD itself is installed via `helm_release` in `modules/eks-addons/gitops.tf`, and `argocd.tf` (root) applies both YAML files as-is via `kubectl_manifest` (the `gavinbunney/kubectl` provider, not `hashicorp/kubernetes`'s `kubernetes_manifest` — the latter needs the target CRD to already exist at `plan` time, which breaks on a fresh cluster where the `Application`/`ApplicationSet` CRDs are installed by the same apply's `argocd` Helm release; `kubectl_manifest` defers validation to apply time instead):

```hcl
resource "kubectl_manifest" "argocd_application" {
  yaml_body  = file("${path.module}/k8s/argocd/application.yaml")
  depends_on = [module.eks_addons]
}
```

The YAML files in `k8s/argocd/` stay the single source of truth — Terraform reads them with `file()` rather than re-expressing them as HCL, so there's no way for the applied object and the committed YAML to drift apart. See [`DEPLOYMENT.md`](DEPLOYMENT.md) and [`TERRAFORM.md`](TERRAFORM.md#root-argocdtf).

## `k8s/services/catalog-service/`

The reference microservice — `user-service`, `order-service`, and `notification-service` follow the identical layout below (own namespace, own schema, own `ExternalSecret`/`admin-db-secret`, own `schema-init-job.yaml` PreSync hook). `api-gateway` is the one structural exception — see [`k8s/services/api-gateway/`](#k8sservicesapi-gateway) below.

```
base/
  namespace.yaml         — "catalog" namespace
  configmap.yaml          — DB_PORT, DB_NAME=catalog_db, APP_PORT
  external-secret.yaml     — catalog-db-secret, reads /bookstore/catalog-db-credentials
  admin-db-secret.yaml      — admin-db-secret, reads /bookstore/db-credentials (for the schema-init hook)
  schema-init-job.yaml       — ArgoCD PreSync hook, see below
  deployment.yaml              — plain Deployment (not a Rollout — canary comes later, with the gateway)
  service.yaml                   — ClusterIP :80 → :3000
  hpa.yaml                        — CPU 70% / memory 80%, 1-5 replicas
  pdb.yaml                         — minAvailable: 1
  network-policy.yaml                — default-deny + catalog-service allow-all-ingress (deliberately open — see below)
  kustomization.yaml
overlays/prod/
  kustomization.yaml                    — image tag placeholder, same pattern as the monolith's prod overlay
```

### NetworkPolicy — now scoped to the gateway namespace

The original interim state (`ingress: - {}`, allow-all, because there was no `api-gateway` namespace yet to scope to) is gone. Now that `api-gateway` exists, `catalog-service`/`user-service`/`order-service`'s `network-policy.yaml` restricts ingress to pods in the `gateway` namespace (commit `153bed2`):

```yaml
ingress:
  - from:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: gateway
```

The egress rule stays scoped to RDS CIDR + DNS only, unchanged from before. There is still no public Ingress routing directly to these services — they're reachable only via `api-gateway`'s proxy or `kubectl port-forward` for local verification.

## `k8s/services/api-gateway/`

Structurally different from the other 4 services: no DB schema, no `schema-init-job.yaml`, no `admin-db-secret.yaml`. Its `base/` adds `ingress.yaml` — the one microservice with a real public `Ingress`:

```yaml
spec:
  ingressClassName: nginx
  tls:
    - hosts: [api.bookstore.<domain>]
      secretName: gateway-tls
  rules:
    - host: api.bookstore.<domain>
      http:
        paths:
          - path: /
            backend: { service: { name: gateway-service, port: { number: 80 } } }
```

**This used to collide with the old monolith's ingress; it no longer does.** `k8s/base/ingress/ingress.yaml` (still deployed, still ArgoCD-managed via `k8s/argocd/application.yaml`) used to declare `api.bookstore.<domain>` too, routing to `backend-service` in the `bookstore` namespace. That rule was removed as part of the frontend build ([Plan 5](superpowers/plans/2026-08-08-frontend-microservices-integration.md)) — `api-gateway`'s `Ingress` is now the sole owner of that host, verified live: `POST /books` without a JWT returns `401` from the gateway. `k8s/base/ingress/ingress.yaml` now only routes `bookstore.<domain>` (frontend static assets). See [`FUTURE_IMPROVEMENTS.md`](FUTURE_IMPROVEMENTS.md) gap #12.

`api-gateway`'s own `network-policy.yaml` allows ingress from the ALB (by VPC CIDR, not a namespace selector — see OBS-057, the ALB connects straight to pod IPs from its own ENIs, not from a pod in some ingress-controller namespace the way ingress-nginx used to) and egress to the other 4 services' namespaces plus RDS-adjacent DNS.

### The schema-init Job — an ArgoCD PreSync hook, not a manual one-off

Terraform creates the `catalog_db_credentials` secret (random password, `catalog_user` username) but can't run arbitrary SQL against RDS. `schema-init-job.yaml` is the `batch/v1 Job` that does the SQL work: creates the `catalog_db` schema, creates/migrates the `books` table (copying existing rows from the monolith's `test.books` table), creates the `catalog_user` MySQL user, and grants it access to only `catalog_db`.

It's annotated as an ArgoCD hook:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: HookSucceeded
```

`PreSync` means it runs before every sync of the `catalog-service` Application, automatically — no manual `kubectl apply`. `HookSucceeded` deletes the Job after it completes, so the next sync creates a fresh one under the same name instead of colliding with a completed one. ArgoCD's normal `selfHeal`/prune diffing doesn't apply to hooks the way it would to a plain resource in the base — this is specifically why it's now safe to include in `base/kustomization.yaml` (a plain, non-hook Job would fight `selfHeal` on every sync, which is why it used to be kept out entirely). The SQL itself was already written idempotently (`CREATE ... IF NOT EXISTS`, `INSERT ... ON DUPLICATE KEY UPDATE`), which is exactly what makes it safe to actually re-run on every sync rather than just the first one.

It needs **both** the admin credentials and the new service's own credentials. Admin creds no longer require a manual cross-namespace copy: `admin-db-secret.yaml` is a second `ExternalSecret` that pulls the same `/bookstore/db-credentials` entry the monolith already uses, materialized into the `catalog` namespace by ESO — no new IAM permissions needed, since the shared `ClusterSecretStore`'s IRSA role is already scoped to all of `/bookstore/*`. The Job's pod template also carries the `app: catalog-service` label — without it, the namespace's `default-deny-all` NetworkPolicy would block its egress to RDS, since it wouldn't match `catalog-service-policy`'s pod selector.

## Metrics convention (every service, old and new)

```javascript
const registry = new Registry();
registry.setDefaultLabels({ service: SERVICE_NAME });
collectDefaultMetrics({ register: registry });

const httpRequests = new Counter({
  name: "http_requests_total",
  labelNames: ["method", "route", "status"],
  registers: [registry],
});
```

`GET /metrics` (prom-client), `GET /health` (liveness/readiness target), `service` label applied once via `registry.setDefaultLabels` rather than as an explicit `labelNames` entry passed to every `.labels()` call — simpler, and every service copying this file for the next microservice doesn't have to remember to pass an extra positional argument correctly.

## Common commands

```bash
# render manifests without applying
kubectl kustomize k8s/overlays/prod
kubectl kustomize k8s/services/catalog-service/overlays/prod

# check what ArgoCD is managing
kubectl get applications -n argocd
kubectl get applicationsets -n argocd

# force a sync outside the 3-minute poll
kubectl -n argocd patch application bookstore --type merge -p '{"operation":{"sync":{}}}'

# tail rollout progress
kubectl argo rollouts get rollout backend -n bookstore --watch
```

## Related

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — system-level view
- [`DEPLOYMENT.md`](DEPLOYMENT.md) — how to actually apply all of this
- [`CICD.md`](CICD.md) — how images get built and how tags get bumped
- [`../explaination/DOCKER_EXPLAINED.md`](../explaination/DOCKER_EXPLAINED.md) — the Dockerfiles themselves, and how each image's non-root design pairs with the `securityContext` blocks in these manifests
- [Plan 1](superpowers/plans/2026-07-30-catalog-service.md) — exact task-by-task history of how catalog-service was built
