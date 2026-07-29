# Design: Microservices Split + Observability

**Branch:** `observability`
**Date:** 2026-07-29
**Status:** Approved — proceeding to implementation plan

## Goal

Split the current monolithic Express backend into 5 real, independently-deployed
microservices, and extend the existing EC2-based Prometheus/Grafana stack to
monitor all of them with PromQL-ready metrics.

## Non-goals (explicitly deferred)

- Service mesh / Istio / mTLS
- Async messaging (SQS/SNS) between services
- Per-service RDS instance isolation (schema-level isolation only, for now)
- Distributed tracing (X-Ray/Jaeger)
- NetworkPolicy hardening beyond a basic default set
- Any Jira/sprint/agile-lab process — this is a straight engineering build

These match the original Phase 3 brainstorm (`BRAINSTORM_AGILE_PHASES.md`,
sprints 6–7 scope) minus the mesh/async/tracing work in sprints 10–12, and
entirely minus the mentoring-lab framing in `project-phase3-brainstorm` memory.

## Current state (baseline)

`backend/app.js` is a single Express app with one domain: books CRUD
(`GET/POST/PUT/DELETE /books`), plus `/health` and `/metrics` (prom-client,
already wired with `http_requests_total` counter and `http_request_duration_seconds`
histogram). No user/auth, order, or notification logic exists anywhere in the
repo today — those three services are net-new feature builds, not extractions.

## Service boundaries

| Service | Owns | Key endpoints |
|---|---|---|
| `catalog-service` | books | `GET/POST/PUT/DELETE /books`, `/health`, `/metrics` |
| `user-service` | users, auth | `POST /auth/register`, `POST /auth/login`, `GET /users/me`, `/health`, `/metrics` |
| `order-service` | orders | `POST /orders`, `GET /orders`, `GET /orders/:id`, `/health`, `/metrics` |
| `notification-service` | notification log | `POST /notify` (internal, called by order-service), `/health`, `/metrics` |
| `api-gateway` | routing, auth enforcement | proxies all of the above, `/health`, `/metrics` |

Each service is its own Node.js/Express app: own `package.json`, own
`Dockerfile`, own `prom-client` registry reusing the counter/histogram pattern
already in `catalog-service` (ported verbatim from current `app.js`).

## Data layer

Single existing RDS MySQL instance, split into 3 logical schemas:

- `catalog_db` — `books` table (migrated as-is from current schema)
- `user_db` — `users` table (`id`, `email` unique, `password_hash`, `created_at`)
- `order_db` — `orders` table (`id`, `user_id`, `book_id`, `quantity`, `status`, `created_at`)

`notification-service` also gets a lightweight `notification_db` schema
(`notification_log`: `id`, `order_id`, `channel`, `status`, `sent_at`) so
delivery attempts are queryable, even though it's not itself an
order-of-record store.

Each service authenticates to MySQL with its own DB user, scoped to only its
schema. Credentials continue to flow through the existing pattern: Secrets
Manager entry → External Secrets Operator → K8s Secret → env vars. This is
schema-level isolation now, with a clean seam to full RDS-per-service later
without an app-level rewrite.

## Auth

- `user-service` issues JWT (HS256) on login/register. Shared signing secret
  lives in Secrets Manager (`/bookstore/jwt-secret`), synced via ESO to any
  service that needs to verify tokens (`api-gateway`, `order-service`).
- `api-gateway` verifies JWT as Express middleware on protected routes and
  forwards identity downstream via `X-User-Id` header. Downstream services
  trust that header (gateway is the only ingress path — enforced by
  NetworkPolicy denying direct external access to service pods).
- Protected routes: all of `/orders/*`, `GET /users/me`, and book mutations
  (`POST/PUT/DELETE /books`) now require auth. Book reads (`GET /books`)
  stay public.

## Inter-service comms

REST only, synchronous, no queue. Flow: `order-service` writes the order row,
responds 201 to the caller, then makes a best-effort async (fire-and-forget,
short timeout, e.g. 2s) HTTP call to `notification-service /notify`. Failures
there are caught, logged, and counted in a `notification_dispatch_failures_total`
metric — never surfaced to the order caller and never block the order
response. This mirrors the eventual-consistency behavior an SQS queue would
give without standing up SQS now (explicitly deferred, see Non-goals).

## API gateway choice

Node/Express + `http-proxy-middleware`, not nginx/Kong. Rationale: keeps the
whole platform on the stack already in use everywhere else in this repo, and
lets JWT verification be ordinary Express middleware instead of requiring an
nginx auth module or a new piece of gateway software to operate. Path routing:

```
/books*          -> catalog-service
/auth/*, /users* -> user-service
/orders*         -> order-service
(no external route to notification-service — internal only)
```

## Infra / deployment layout

**Terraform:**
- 5 ECR repos (extend existing `modules/ecr`, or new `modules/ecr-microservices` — decide in plan)
- 5 K8s namespaces: `catalog`, `user`, `order`, `notification`, `gateway`
- Per-service IRSA role scoped to only its own Secrets Manager path

**K8s (new tree):** `k8s/services/<name>/` per service — Deployment, Service,
HPA, PDB, basic NetworkPolicy (deny-all except from `gateway` namespace + from
monitoring EC2 box's ENI for scraping), ExternalSecret. Kustomize base +
prod/dev overlays per service, following the existing `k8s/base` /
`k8s/overlays` pattern.

**ArgoCD:** One `ApplicationSet` templated over the 5 services, rather than 5
hand-authored `Application` manifests — less duplication, one place to change
sync policy for all of them.

**CI/CD:** Extend `.github/workflows/ci-cd.yml` with path-based change
detection (`dorny/paths-filter` or similar) so a change to one service only
rebuilds/redeploys that service, not all 5. Reuses the existing 3-stage
pattern (scan → build/push to ECR via OIDC → `kustomize edit set image` +
ArgoCD sync).

**Old backend removal:** `backend/` (current monolith) is migrated into
`catalog-service` and then deleted, along with its old K8s manifests in
`k8s/base/`. ArgoCD has auto-prune enabled — leaving the old Deployment/Service
around after the new ones land risks prune conflicts or duplicate traffic
targets. This is a one-way cutover, not a parallel-run.

## Observability

- Every service exposes `/metrics` via the same prom-client
  counter+histogram pattern already in `catalog-service`'s `app.js`
  (`http_requests_total`, `http_request_duration_seconds`, both labeled
  `method`/`route`/`status`), plus a `service` label added to every metric so
  PromQL can filter/aggregate across services.
- EC2 Prometheus (`modules/monitoring-ec2`, Docker Compose config) gets a new
  `kubernetes_sd_configs` scrape job targeting pods in the 5 new namespaces,
  relabeled to set the `service`/`namespace` labels. No new infra — this
  extends the box that already scrapes the cluster over the network for the
  Argo Rollouts analysis metrics.
- Grafana: one dashboard per service (request rate, p99 latency, error rate,
  pod restarts — same 4 panels as the existing backend dashboard) plus one
  cross-service overview dashboard using a `service` template variable, e.g.:
  ```promql
  sum(rate(http_requests_total{service=~"$service"}[5m])) by (service, status)
  histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{service=~"$service"}[5m])) by (le, service))
  ```
- Alertmanager: per-service error-rate and crash-loop alert rules, following
  the existing rule pattern, minus anything SQS-dead-letter-related (no queue
  yet).

## Testing

vitest per service, mirroring `backend/__tests__/books.test.js`. Each service
ships its own test suite exercising its own endpoints against a test DB
connection (same `createApp(db)` factory pattern as today, just repeated per
service).

## Open risks / things the implementation plan should address explicitly

- Cutover order matters: catalog-service must be live and serving before
  `backend/` is deleted, to avoid downtime.
- `X-User-Id` trust boundary depends on NetworkPolicy actually blocking direct
  external access to service pods — must be verified, not assumed.
- Shared JWT secret rotation story is not designed here (out of scope for
  this branch); rotation would currently require restarting every service
  that verifies tokens.
