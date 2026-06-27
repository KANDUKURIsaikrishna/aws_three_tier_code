# Design Spec: Agile Learning Lab — Bookstore on AWS
**Date:** 2026-06-25
**Status:** Draft — not committed to git
**Author:** Kandukuri Saikrishna

---

## 1. Purpose

Use the bookstore AWS project as a real-world agile simulation for DevOps/Infra mentees. The mentor acts as Product Owner presenting business requirements; mentees plan sprints, own tickets, coordinate as a team, and build the platform from scratch. The reference implementation already exists in the repo — mentees discover the solution by building it.

---

## 2. Roles

| Role | Person | Responsibilities |
|------|--------|-----------------|
| Product Owner / Customer | Mentor | Present PRD at each Epic boundary, accept/reject sprint demos, play customer role |
| DevOps/Infra Engineers | Mentees | Sprint planning, ticket ownership, infrastructure build, coordination |
| Scrum Master (optional) | Rotating mentee | Run standups, track blockers, update Jira board |

**Mentee profile:** Intermediate DevOps/Infra — knows AWS basics and Kubernetes concepts, first time doing end-to-end platform build in a team setting.

---

## 3. Tooling

| Tool | Purpose |
|------|---------|
| Jira Free | Epics, Stories, Tickets, Sprint boards |
| GitHub | Source code, CI/CD pipelines (existing repo) |
| Slack / Discord | Team communication, standup async |
| AWS (per-mentee accounts) | Individual sandboxes — prevents Terraform state conflicts |

> **Critical:** Individual AWS accounts per mentee. Shared sandbox causes Terraform state lock collisions and makes Sprint 1 unworkable.

---

## 4. Agile Ceremony Structure

| Ceremony | Cadence | Duration |
|----------|---------|----------|
| Sprint Planning | Start of every sprint | 1-2 hours |
| Daily Standup | Every working day | 15 min async or sync |
| Sprint Demo | End of every sprint | 30-45 min — must hit Ship Gate |
| Retrospective | End of every phase (not every sprint) | 1 hour |
| PRD Presentation | Before each Epic starts | 30-60 min — mentor plays customer |

---

## 5. Definition of Done (per ticket type)

| Ticket Type | Definition of Done |
|-------------|-------------------|
| terraform | `terraform plan` shows no drift, `terraform apply` succeeds, resource visible in AWS console |
| k8s | `kubectl get <resource>` shows Ready/Running, logs clean |
| ci-cd | Pipeline passes end-to-end in GitHub Actions, no manual steps required |
| observability | Metric/trace/dashboard visible and populated with live data |
| security | Tool (tfsec/Checkov/Trivy) shows 0 HIGH findings, reviewer signs off |
| architecture | Doc reviewed + approved by PO before implementation begins |

---

## 6. Phase Map

### Phase 1 — Foundation
**Theme:** Build a 3-tier bookstore app on AWS from scratch
**Branch reference:** `main`
**Duration:** 2 sprints × 1 week = ~2 weeks
**Epic Ship Criteria:** App accessible at `https://bookstore.domain`, CI/CD pipeline green

### Phase 2 — Hardening
**Theme:** Make the platform production-worthy
**Branch reference:** `improvements`
**Duration:** 3 sprints × 1 week = ~3 weeks
**Epic Ship Criteria:** All add-ons IaC-managed, Grafana live, canary rollouts working, tests in CI

### Phase 3 — Microservices Platform
**Theme:** Evolve monolith infra to support 5-service microservices architecture
**Branch reference:** `phase-3` (new branch)
**Duration:** 5 sprints × 2 weeks = ~10 weeks
**Epic Ship Criteria:** 5 services independently deployed, mTLS enforced, async events flowing, distributed traces visible

**Total: ~15 weeks, 70 tickets**

---

## 7. Microservices Architecture (Phase 3)

```
bookstore-frontend (React)           → unchanged
         ↓ HTTPS
api-gateway (nginx)                  → routes by path prefix
    ├── /api/books        →  catalog-service      (Node.js — CRUD books)
    ├── /api/users        →  user-service         (Node.js — auth, JWT, registration)
    ├── /api/orders       →  order-service        (Node.js — cart, purchase, history)
    └── /api/notify       →  notification-service (Node.js — SES email via SQS consumer)

Inter-service communication:
  Sync  → catalog-service ←→ user-service (REST over mTLS)
  Async → order-service → SQS → notification-service

Each service owns:
  - ECR repo (Terraform)
  - K8s namespace + RBAC
  - Helm chart
  - CI/CD pipeline (GitHub Actions)
  - ArgoCD Application
  - Database schema (isolated)
  - IRSA role (scoped permissions)
  - Prometheus /metrics endpoint
  - Argo Rollout (canary delivery)
```

**App code delivery:** Node.js source provided pre-built. Mentees write Dockerfiles, Helm charts, pipelines, and all infrastructure. No app development required.

---

## 8. Sprint Plan + Ticket Breakdown

### PHASE 1 — FOUNDATION

#### Sprint 1 — Infrastructure Setup *(Week 1)*
**Ship Gate:** `kubectl get nodes` → nodes in Ready state

| Ticket | Title | Label | Est. |
|--------|-------|-------|------|
| INFRA-001 | Bootstrap Terraform remote state (S3 + DynamoDB) | terraform | 0.5d |
| INFRA-002 | VPC module — public/private subnets, IGW, NAT, route tables | terraform | 1d |
| INFRA-003 | EKS cluster + managed node group module | terraform | 1d |
| INFRA-004 | ECR repos — frontend + backend, IMMUTABLE tags, lifecycle policy | terraform | 0.5d |
| INFRA-005 | RDS MySQL module — Secrets Manager password, private subnet group | terraform | 1d |
| INFRA-006 | ACM wildcard certificate module | terraform | 0.5d |
| INFRA-007 | GitHub Actions OIDC provider + scoped IAM role | terraform | 0.5d |
| INFRA-008 | Route53 private zone for RDS internal DNS | terraform | 0.5d |

> **Mentor note:** Sprint 1 is the hardest. 8 Terraform tickets in 1 week is tight for intermediates. Consider allowing 1.5 weeks or pre-baking the S3 state backend before the sprint starts.

---

#### Sprint 2 — Application Deployment *(Week 2)*
**Ship Gate:** `curl https://bookstore.domain` → app responds; CI pipeline green end-to-end

| Ticket | Title | Label | Est. |
|--------|-------|-------|------|
| K8S-001 | Apply gp3 StorageClass manifest (declarative) | k8s | 0.5d |
| K8S-002 | Configure cluster-issuer (cert-manager, Let's Encrypt) | k8s | 0.5d |
| K8S-003 | Deploy ESO SecretStore + ExternalSecret for DB credentials | k8s | 1d |
| K8S-004 | K8s manifests: frontend Deployment + Service + ConfigMap | k8s | 0.5d |
| K8S-005 | K8s manifests: backend Deployment + Service + HPA | k8s | 0.5d |
| K8S-006 | Ingress with TLS (bookstore.domain + api.bookstore.domain) | k8s | 0.5d |
| CICD-001 | CI Stage 1: Gitleaks + Semgrep + npm audit + Trivy image scan | ci-cd | 1d |
| CICD-002 | CI Stage 2: Docker build + push to ECR (OIDC auth) | ci-cd | 0.5d |
| CICD-003 | CI Stage 3: Terraform plan/apply with manual prod approval gate | ci-cd | 0.5d |
| CICD-004 | Configure ArgoCD Application — GitOps sync from k8s/ | ci-cd | 0.5d |

---

### PHASE 2 — HARDENING

#### Sprint 3 — IaC + GitOps Hardening *(Week 3)*
**Ship Gate:** All add-ons Terraform-managed, Kustomize overlays deployed, ArgoCD syncing from `overlays/prod`

| Ticket | Title | Label | Est. |
|--------|-------|-------|------|
| INFRA-009 | eks-addons Terraform module (cert-manager, ESO, ingress-nginx, ArgoCD) | terraform | 1.5d |
| INFRA-010 | Add Argo Rollouts to eks-addons module | terraform | 0.5d |
| K8S-007 | Create Kustomize base manifests (extract from k8s/) | k8s | 1d |
| K8S-008 | Dev overlay — lower replicas, in-cluster MySQL DB host | k8s | 0.5d |
| K8S-009 | Prod overlay — resource limits, RDS DB host, prod replica counts | k8s | 0.5d |
| K8S-010 | Update ArgoCD Application to sync from overlays/prod | k8s | 0.5d |
| CICD-005 | Update CI image update step to use `kustomize edit set image` | ci-cd | 0.5d |

---

#### Sprint 4 — Observability *(Week 4)*
**Ship Gate:** Grafana dashboard live with real data, backend `/metrics` scraped by Prometheus

| Ticket | Title | Label | Est. |
|--------|-------|-------|------|
| INFRA-011 | Add kube-prometheus-stack to eks-addons Terraform module | terraform | 1d |
| K8S-011 | Add prom-client to backend, expose /metrics endpoint | k8s | 0.5d |
| K8S-012 | Configure ServiceMonitor for backend Prometheus scraping | k8s | 0.5d |
| K8S-013 | Grafana dashboard: request rate, latency p99, pod restarts, error rate | observability | 1d |
| K8S-014 | Grafana ingress (grafana.domain) + TLS | k8s | 0.5d |

---

#### Sprint 5 — Progressive Delivery + Testing *(Week 5)*
**Ship Gate:** Canary rollout executes 10%→50%→100% with auto-rollback; vitest suite passes in CI Stage 1

| Ticket | Title | Label | Est. |
|--------|-------|-------|------|
| K8S-015 | Convert backend Deployment to Argo Rollout (canary: 10%→50%→100%) | k8s | 1d |
| K8S-016 | Configure Argo Rollout automatic rollback on error rate breach | k8s | 0.5d |
| TEST-001 | Refactor app.js to factory pattern (testable exports) | ci-cd | 0.5d |
| TEST-002 | Write vitest unit tests — 6 tests covering CRUD endpoints | ci-cd | 1d |
| CICD-006 | Wire vitest into CI Stage 1 (before Docker build) | ci-cd | 0.5d |

---

### PHASE 3 — MICROSERVICES PLATFORM

#### Sprint 6-7 — Service Design + Scaffolding *(2 weeks)*
**Ship Gate:** 5 services containerized + deployed, per-service ECR repos live, API gateway routing all paths, architecture diagram signed off by PO

| Ticket | Title | Label | Est. |
|--------|-------|-------|------|
| ARCH-001 | Design service boundaries + OpenAPI contract per service | architecture | 1d |
| ARCH-002 | Inter-service comms decision: sync REST vs async SQS (ADR format) | architecture | 0.5d |
| INFRA-012 | Per-service ECR repos in Terraform (5 repos) | terraform | 0.5d |
| INFRA-013 | SQS queues + SNS topics (order-events, notification-events) | terraform | 1d |
| INFRA-014 | IRSA role per service (scoped SQS/RDS/SES permissions) | terraform | 1d |
| K8S-017 | Per-service namespaces + RBAC (5 namespaces) | k8s | 0.5d |
| K8S-018 | Containerize + deploy catalog-service | k8s | 1d |
| K8S-019 | Containerize + deploy user-service | k8s | 1d |
| K8S-020 | Containerize + deploy order-service | k8s | 1d |
| K8S-021 | Containerize + deploy notification-service | k8s | 1d |
| K8S-022 | Deploy API gateway (nginx) with upstream routing rules per service | k8s | 1d |

---

#### Sprint 8-9 — Per-Service CI/CD + GitOps *(2 weeks)*
**Ship Gate:** All 5 services deploy independently — each has own pipeline, own ArgoCD Application; a change in one service does NOT trigger deploy of others

| Ticket | Title | Label | Est. |
|--------|-------|-------|------|
| CICD-007 | CI/CD pipeline — catalog-service (build→scan→push→deploy) | ci-cd | 1d |
| CICD-008 | CI/CD pipeline — user-service | ci-cd | 1d |
| CICD-009 | CI/CD pipeline — order-service | ci-cd | 1d |
| CICD-010 | CI/CD pipeline — notification-service | ci-cd | 1d |
| CICD-011 | CI/CD pipeline — api-gateway | ci-cd | 0.5d |
| K8S-023 | Helm chart — catalog-service | k8s | 1d |
| K8S-024 | Helm chart — user-service | k8s | 1d |
| K8S-025 | Helm chart — order-service | k8s | 1d |
| K8S-026 | Helm chart — notification-service | k8s | 1d |
| K8S-027 | ArgoCD Application per service (5 total, each points to own Helm chart) | k8s | 1d |
| K8S-028 | Per-service HPA (min/max replicas, CPU target per service profile) | k8s | 0.5d |

---

#### Sprint 10 — Service Mesh + mTLS *(2 weeks)*
**Ship Gate:** Istio installed, mTLS STRICT mode cluster-wide, no service can receive traffic without an explicit AuthorizationPolicy

| Ticket | Title | Label | Est. |
|--------|-------|-------|------|
| INFRA-015 | Add Istio to eks-addons Terraform module (helm_release, istiod + gateway) | terraform | 1.5d |
| K8S-029 | Enable Istio sidecar injection per namespace (label all 5 namespaces) | k8s | 0.5d |
| K8S-030 | PeerAuthentication — mTLS STRICT mode cluster-wide | security | 0.5d |
| K8S-031 | VirtualServices + DestinationRules per service | k8s | 1d |
| K8S-032 | AuthorizationPolicies — explicit service-to-service allow rules | security | 1d |
| K8S-033 | Replace nginx ingress with Istio ingress gateway for mesh traffic | k8s | 1d |

---

#### Sprint 11 — Async Messaging + Data Isolation *(2 weeks)*
**Ship Gate:** `order.placed` SQS event flows from order-service → notification-service → SES email sent; each service reads only its own DB schema

| Ticket | Title | Label | Est. |
|--------|-------|-------|------|
| INFRA-016 | Per-service RDS schema isolation (separate schemas or separate instances) | terraform | 1d |
| INFRA-017 | Secrets Manager entries per service (DB creds, JWT secret, SES config) | terraform | 1d |
| K8S-034 | ExternalSecret per service namespace (each pulls own secrets only) | k8s | 1d |
| APP-001 | order-service publishes `order.placed` event to SQS on order creation | k8s | 1d |
| APP-002 | notification-service SQS consumer → SES email on `order.placed` event | k8s | 1d |
| INFRA-018 | SES identity + IAM sending permissions | terraform | 0.5d |
| ARCH-003 | Saga flow diagram: order create → inventory check → notification (payment mocked) | architecture | 0.5d |

---

#### Sprint 12 — Observability + Security Hardening *(2 weeks)*
**Ship Gate:** X-Ray traces visible end-to-end across all services; NetworkPolicies enforce default-deny; canary rollout configured per service; 0 HIGH security findings

| Ticket | Title | Label | Est. |
|--------|-------|-------|------|
| OBS-001 | AWS X-Ray tracing per service (or Jaeger via Istio) | observability | 1.5d |
| OBS-002 | Per-service Grafana dashboard (request rate, latency, error rate, SQS depth) | observability | 1.5d |
| OBS-003 | Prometheus AlertManager rules (pod crash, high error rate, SQS dead-letter queue) | observability | 1d |
| K8S-035 | NetworkPolicies per namespace — default deny, explicit ingress allow | security | 1d |
| K8S-036 | Pod Security Standards — restricted profile per namespace | security | 0.5d |
| K8S-037 | Convert per-service Deployments to Argo Rollouts (canary per service) | k8s | 1d |
| SEC-001 | Run tfsec + Checkov on Phase 3 Terraform — fix all HIGH findings | security | 1d |
| SEC-002 | RBAC audit: service accounts least-privilege, no wildcard permissions | security | 0.5d |

---

## 9. Ticket Totals

| Phase | Sprints | Duration | Tickets |
|-------|---------|----------|---------|
| Phase 1 — Foundation | 2 × 1wk | 2 weeks | 18 |
| Phase 2 — Hardening | 3 × 1wk | 3 weeks | 17 |
| Phase 3 — Microservices | 5 × 2wk | 10 weeks | 35 |
| **Total** | **10 sprints** | **~15 weeks** | **70** |

---

## 10. PRD Template (per Epic)

Use this structure when presenting requirements to mentees as "customer":

```
## Product Requirements — [Phase Name]

### Business Context
[Why this matters — written as business problem, not tech spec]

### What We Need
[Functional requirements only — what the system must do, not how]

### Success Criteria
[Observable outcomes — what does "done" look like from a business perspective]

### Constraints
[Budget, timeline, compliance, existing systems to integrate with]

### Out of Scope
[Explicitly excluded — prevents scope creep]
```

---

## 11. Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|-----------|
| Sprint 1 runs over 1 week | High | Medium | Pre-create S3 state bucket before sprint starts |
| Shared AWS account causes state conflicts | High | High | Individual accounts mandatory — non-negotiable |
| Phase 3 Istio complexity blocks Sprint 10 | Medium | High | Allocate 2.5 weeks buffer for Sprint 10 if needed |
| Mentees skip architecture tickets (ARCH-*) | Medium | High | ARCH tickets are sprint gates — sprint cannot close without PO sign-off on arch docs |
| App code (Phase 3 services) has bugs that block infra work | Low | Medium | Pre-test all 5 service images before handing to mentees |

---

_This is a local spec document. Not committed to git._
