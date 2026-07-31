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
    catalog-service/
      base/                 ← NEW microservice, namespace "catalog"
      overlays/prod/
      bootstrap/              ← one-off Jobs, not part of any Kustomize base
```

These are deliberately separate. `catalog-service` is not folded into `k8s/base` because it's a different namespace, different lifecycle, different ArgoCD-managed object — mixing them would make the eventual old-backend removal (Plan 4 of the microservices work) much messier than swapping one `targetRevision`/one `Application`.

## `k8s/base/` — the monolith

Resources, in the order `kustomization.yaml` lists them:

| File | What |
|---|---|
| `storageclass/gp3.yaml` | Default gp3 StorageClass |
| `namespace.yaml` | `bookstore` namespace |
| `cert-manager/cluster-issuer.yaml` | Let's Encrypt `ClusterIssuer` |
| `configmaps/backend-config.yaml` | `DB_PORT`, `DB_NAME`, `APP_PORT` |
| `secrets/external-secret.yaml` | `ClusterSecretStore` + `db-secret` `ExternalSecret` |
| `backend/rollout.yaml` | Argo `Rollout` (not a plain Deployment — canary strategy) |
| `backend/service.yaml` | ClusterIP, port 80 → 3000 |
| `frontend/deployment.yaml`, `frontend/service.yaml` | plain Deployment + Service |
| `ingress/ingress.yaml` | TLS ingress for the domain + `api.<domain>` |
| `network-policy/network-policy.yaml` | default-deny + explicit frontend/backend allow rules |
| `pdb/pdb.yaml` | PodDisruptionBudgets for both |
| `quota.yaml` | namespace ResourceQuota |
| `monitoring/servicemonitor.yaml`, `monitoring/prometheus-rules.yaml`, `monitoring/analysis-template.yaml` | CRD manifests — **inert**, see below |

`k8s/base/database/` (`mysql-statefulset.yaml`, `mysql-service.yaml`, `mysql-init-configmap.yaml`) exists on disk but is **not referenced by `kustomization.yaml`**. Dead files from an earlier in-cluster-MySQL design. RDS is the real database. Don't apply these by hand — they'd create a second, empty, unused MySQL instance.

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
template:
  spec:
    source:
      path: 'k8s/services/{{service}}/overlays/prod'
    destination:
      namespace: '{{namespace}}'
```

Adding `user-service`, `order-service`, etc. later is a one-line addition to `elements` — no new YAML file. **`targetRevision` is currently pinned to `observability`**, not `main`, since this whole platform is being built on that branch — there's a comment in the file as a reminder to switch it once the work merges, but nothing enforces that automatically. Don't assume it self-corrects.

Prerequisites for both (one-time, outside Terraform — ArgoCD itself is installed via `helm_release` in `modules/eks-addons/gitops.tf`, but the `Application`/`ApplicationSet` custom resources themselves need `kubectl apply`):

```bash
kubectl apply -f k8s/argocd/application.yaml
kubectl apply -f k8s/argocd/applicationset-microservices.yaml
```

## `k8s/services/catalog-service/`

The first (and so far only) built microservice.

```
base/
  namespace.yaml         — "catalog" namespace
  configmap.yaml          — DB_PORT, DB_NAME=catalog_db, APP_PORT
  external-secret.yaml     — catalog-db-secret, reads /bookstore/catalog-db-credentials
  deployment.yaml            — plain Deployment (not a Rollout — canary comes later, with the gateway)
  service.yaml                 — ClusterIP :80 → :3000
  hpa.yaml                      — CPU 70% / memory 80%, 1-5 replicas
  pdb.yaml                       — minAvailable: 1
  network-policy.yaml              — default-deny + catalog-service allow-all-ingress (deliberately open — see below)
  kustomization.yaml
overlays/prod/
  kustomization.yaml                — image tag placeholder, same pattern as the monolith's prod overlay
bootstrap/
  schema-init-job.yaml                — one-off, NOT in any kustomization
```

### Why the NetworkPolicy allows all ingress

```yaml
ingress:
  - {} # tightened in Plan 4 once api-gateway exists and owns ingress
```

There's no `api-gateway` namespace yet to scope traffic to, and no public Ingress object routes to `catalog-service` at all right now (it's only reachable via `kubectl port-forward` for verification). The egress rule right next to it *is* properly scoped (RDS CIDR + DNS only, nothing else) — the permissive ingress is a deliberate, documented interim state tied to a specific future plan, not an oversight. Don't "fix" it without also building the api-gateway plan it's waiting on.

### The schema-init Job

Terraform creates the `catalog_db_credentials` secret (random password, `catalog_user` username) but can't run arbitrary SQL against RDS. `bootstrap/schema-init-job.yaml` is a one-shot `batch/v1 Job` that does the SQL work: creates the `catalog_db` schema, creates/migrates the `books` table (copying existing rows from the monolith's `test.books` table), creates the `catalog_user` MySQL user, and grants it access to only `catalog_db`. It needs **both** the admin credentials (`db-secret`, namespace `bookstore`) and the new service credentials (`catalog-db-secret`, namespace `catalog`) — since K8s Secrets don't cross namespaces, the admin secret has to be copied into `catalog` by hand right before running this Job (see [`DEPLOYMENT.md`](DEPLOYMENT.md)), then deleted afterward. It's a one-time bootstrap tool, not a standing credential bridge.

Deliberately kept out of `base/kustomization.yaml`: a completed `Job` is immutable, and ArgoCD's `selfHeal` would either error trying to re-apply it or (worse) try to delete-and-recreate it on every sync.

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
- [Plan 1](superpowers/plans/2026-07-30-catalog-service.md) — exact task-by-task history of how catalog-service was built
