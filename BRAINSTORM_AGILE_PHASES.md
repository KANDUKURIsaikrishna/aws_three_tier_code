# Brainstorm: Agile Phases + Microservices Learning Lab
_Local draft — NOT committed to git. Last updated: 2026-06-25_

---

## Concept

Simulate a real-world agile SDLC using this bookstore project as the reference implementation.

| Role | Person |
|------|--------|
| Product Owner / Customer | You (mentor) |
| Dev Team | Mentees (DevOps/Infra, intermediate level) |

You present requirements as a "customer." Mentees plan sprints, take tickets, coordinate, and build. You already know the answer (the repo). They discover it.

---

## Decisions Made

| Decision | Choice |
|----------|--------|
| Mentee level | Intermediate (DevOps/Infra only, no app devs) |
| Team size | Flexible — tickets scalable 1-person to 8+ |
| Sprint cadence | Variable: 1-week for Phase 1/2, 2-week for Phase 3 |
| Ticket tool | Jira Free edition |
| GitHub commits | None for agile artifacts — Jira + local docs only |
| Phase 3 focus | Infra/platform for microservices, NOT app code splitting |
| Structure | Linear phases (A) + Ship Something each sprint (C) |
| Phase 3 services | 5 services: catalog, user, order, notification, api-gateway |

---

## Overall Sprint Map

```
Epic 1 — Foundation       │ 2 sprints × 1 week  │ ~2 weeks
Epic 2 — Hardening        │ 3 sprints × 1 week  │ ~3 weeks
Epic 3 — Microservices    │ 5 sprints × 2 weeks │ ~10 weeks
                                                   ──────────
                                                   ~15 weeks total
```

### Ship Gates per Sprint

| Sprint | Ship Gate |
|--------|-----------|
| S1 | `kubectl get nodes` → healthy cluster |
| S2 | `curl https://bookstore.domain` → app live, pipeline green |
| S3 | All add-ons Terraform-managed, Kustomize overlays deployed |
| S4 | Grafana dashboard live, backend /metrics scraped |
| S5 | Canary rollout 10→50→100%, vitest passes in CI |
| S6-7 | 5 services containerized, per-service ECR + namespaces, API gateway routing |
| S8-9 | All 5 services deployed independently, per-service CI/CD + ArgoCD app |
| S10 | Istio mTLS STRICT between all services, traffic policies live |
| S11 | SQS async events order→notification flowing, per-service DB isolation |
| S12 | X-Ray traces end-to-end, per-service Grafana, canary per service |

---

## Microservices Decomposition (Phase 3)

```
bookstore-frontend (React)           → unchanged, deployed as before
    ↓ HTTP
api-gateway (nginx/Kong/AWS APIGW)  → routes to services
    ├── /books        → catalog-service    (CRUD books)
    ├── /users        → user-service       (auth, JWT, registration)
    ├── /orders       → order-service      (purchase, cart, history)
    └── /notify       → notification-svc   (email via SES/SNS)

Each service owns:
  - ECR repo
  - K8s namespace
  - Helm chart
  - CI/CD pipeline
  - Database schema
  - ArgoCD Application
  - Prometheus /metrics endpoint
```

---

## Jira Structure

- 1 Jira project
- 3 Epics (one per phase)
- ~55-60 tickets total
- Labels: terraform / k8s / ci-cd / observability / security / architecture

---

## Agile Artifacts Needed

1. **PRD** — you present as "customer" at each Epic boundary
2. **Epics** — 3 total, one per phase
3. **User Stories** — per component within each Epic
4. **Tickets** — granular, 1-3 days each, 1-per-person assignable
5. **Sprint Plans** — which tickets per sprint
6. **Definition of Done** — per ticket type
7. **Retrospective template** — end of each sprint

---

## PHASE 1 — Foundation (Epic 1)
**Theme:** Build 3-tier app on AWS from scratch
**Branch:** main

### Sprint 1 — Infrastructure Setup *(1 week)*
**Ship Gate:** `kubectl get nodes` → healthy nodes

| Ticket | Title | Label |
|--------|-------|-------|
| INFRA-001 | Bootstrap Terraform remote state (S3 bucket + DynamoDB table) | terraform |
| INFRA-002 | Build VPC module — public/private subnets, IGW, NAT, route tables | terraform |
| INFRA-003 | Build EKS cluster + managed node group module | terraform |
| INFRA-004 | Create ECR repos (frontend + backend), IMMUTABLE tags, lifecycle policy | terraform |
| INFRA-005 | Create RDS MySQL module — Secrets Manager password, private subnet group | terraform |
| INFRA-006 | Create ACM wildcard certificate module | terraform |
| INFRA-007 | Configure GitHub Actions OIDC provider + scoped IAM role | terraform |
| INFRA-008 | Create Route53 private zone for RDS internal DNS | terraform |

### Sprint 2 — Application Deployment *(1 week)*
**Ship Gate:** `curl https://bookstore.domain` → app live, CI pipeline green

| Ticket | Title | Label |
|--------|-------|-------|
| K8S-001 | Apply gp3 StorageClass manifest (declarative) | k8s |
| K8S-002 | Configure cluster-issuer (cert-manager, Let's Encrypt) | k8s |
| K8S-003 | Deploy ESO SecretStore + ExternalSecret for DB credentials | k8s |
| K8S-004 | K8s manifests: frontend Deployment + Service + ConfigMap | k8s |
| K8S-005 | K8s manifests: backend Deployment + Service + HPA | k8s |
| K8S-006 | Ingress with TLS (bookstore.domain + api.bookstore.domain) | k8s |
| CICD-001 | CI Stage 1: Gitleaks + Semgrep + npm audit + Trivy image scan | ci-cd |
| CICD-002 | CI Stage 2: Docker build + push to ECR (OIDC auth) | ci-cd |
| CICD-003 | CI Stage 3: Terraform plan/apply with manual prod approval gate | ci-cd |
| CICD-004 | Configure ArgoCD Application — GitOps sync from k8s/ | ci-cd |

**Phase 1 total: 18 tickets**

---

## PHASE 2 — Hardening (Epic 2)
**Theme:** Make it production-worthy
**Branch:** improvements

### Sprint 3 — IaC + GitOps Hardening *(1 week)*
**Ship Gate:** All add-ons Terraform-managed, Kustomize overlays deployed, ArgoCD syncing from `overlays/prod`

| Ticket | Title | Label |
|--------|-------|-------|
| INFRA-009 | Create eks-addons Terraform module (cert-manager, ESO, ingress-nginx, ArgoCD) | terraform |
| INFRA-010 | Add Argo Rollouts to eks-addons module | terraform |
| K8S-007 | Create Kustomize base manifests (extract from current k8s/) | k8s |
| K8S-008 | Create dev overlay (lower replicas, in-cluster MySQL DB host) | k8s |
| K8S-009 | Create prod overlay (resource limits, RDS DB host, prod replica counts) | k8s |
| K8S-010 | Update ArgoCD Application to sync from overlays/prod | k8s |
| CICD-005 | Update CI image update step to use `kustomize edit set image` | ci-cd |

### Sprint 4 — Observability *(1 week)*
**Ship Gate:** Grafana dashboard live, backend `/metrics` scraped by Prometheus

| Ticket | Title | Label |
|--------|-------|-------|
| INFRA-011 | Add kube-prometheus-stack to eks-addons Terraform module | terraform |
| K8S-011 | Add prom-client to backend, expose /metrics endpoint | k8s |
| K8S-012 | Configure ServiceMonitor for backend Prometheus scraping | k8s |
| K8S-013 | Create Grafana dashboard: request rate, latency p99, pod restarts, error rate | observability |
| K8S-014 | Configure Grafana ingress (grafana.domain) + TLS | k8s |

### Sprint 5 — Progressive Delivery + Testing *(1 week)*
**Ship Gate:** Canary rollout executes 10→50→100%, vitest passes in CI before Docker build

| Ticket | Title | Label |
|--------|-------|-------|
| K8S-015 | Convert backend Deployment to Argo Rollout (canary: 10%→50%→100%) | k8s |
| K8S-016 | Configure Argo Rollout automatic rollback on error rate breach | k8s |
| TEST-001 | Refactor app.js to factory pattern (testable exports) | ci-cd |
| TEST-002 | Write vitest unit tests — 6 tests covering CRUD endpoints | ci-cd |
| CICD-006 | Wire vitest into CI Stage 1 (runs before Docker build) | ci-cd |

**Phase 2 total: 17 tickets**

---

## PHASE 3 — Microservices Platform (Epic 3)
**Theme:** Platform infra for 5-service microservices architecture
**Branch:** phase-3 (new)

### Sprint 6-7 — Service Design + Scaffolding *(2 weeks)*
**Ship Gate:** 5 services containerized, per-service ECR repos live, API gateway routing, architecture diagram signed off

| Ticket | Title | Label |
|--------|-------|-------|
| ARCH-001 | Design service boundaries + OpenAPI contract per service | architecture |
| ARCH-002 | Decide inter-service comms: sync REST (catalog/user) vs async SQS (order→notification) | architecture |
| INFRA-012 | Create per-service ECR repos in Terraform (5 repos) | terraform |
| INFRA-013 | Create SQS queues + SNS topics (order-events, notification-events) | terraform |
| INFRA-014 | Create IRSA role per service (scoped to its own SQS/RDS/SES permissions) | terraform |
| K8S-017 | Create per-service namespaces + RBAC (5 namespaces) | k8s |
| K8S-018 | Containerize + deploy catalog-service | k8s |
| K8S-019 | Containerize + deploy user-service | k8s |
| K8S-020 | Containerize + deploy order-service | k8s |
| K8S-021 | Containerize + deploy notification-service | k8s |
| K8S-022 | Deploy API gateway (nginx) with upstream routing rules per service | k8s |

### Sprint 8-9 — Per-Service CI/CD + GitOps *(2 weeks)*
**Ship Gate:** All 5 services deploy independently — own pipeline, own ArgoCD Application

| Ticket | Title | Label |
|--------|-------|-------|
| CICD-007 | CI/CD pipeline for catalog-service (build→scan→push→deploy) | ci-cd |
| CICD-008 | CI/CD pipeline for user-service | ci-cd |
| CICD-009 | CI/CD pipeline for order-service | ci-cd |
| CICD-010 | CI/CD pipeline for notification-service | ci-cd |
| CICD-011 | CI/CD pipeline for api-gateway | ci-cd |
| K8S-023 | Helm chart for catalog-service | k8s |
| K8S-024 | Helm chart for user-service | k8s |
| K8S-025 | Helm chart for order-service | k8s |
| K8S-026 | Helm chart for notification-service | k8s |
| K8S-027 | ArgoCD Application per service (5 total) | k8s |
| K8S-028 | Per-service HPA (min/max replicas, CPU target per service profile) | k8s |

### Sprint 10 — Service Mesh + mTLS *(2 weeks)*
**Ship Gate:** Istio installed, mTLS STRICT cluster-wide, no service calls without explicit AuthorizationPolicy

| Ticket | Title | Label |
|--------|-------|-------|
| INFRA-015 | Add Istio to eks-addons Terraform module (helm_release) | terraform |
| K8S-029 | Enable Istio sidecar injection per namespace (5 namespaces) | k8s |
| K8S-030 | Configure PeerAuthentication — mTLS STRICT mode cluster-wide | security |
| K8S-031 | Create VirtualServices + DestinationRules per service | k8s |
| K8S-032 | Create AuthorizationPolicies — explicit service-to-service allow rules | security |
| K8S-033 | Replace nginx ingress with Istio ingress gateway | k8s |

### Sprint 11 — Async Messaging + Data Isolation *(2 weeks)*
**Ship Gate:** order→SQS→notification flow working, each service reads only its own DB schema

| Ticket | Title | Label |
|--------|-------|-------|
| INFRA-016 | Per-service RDS schema isolation | terraform |
| INFRA-017 | Secrets Manager entries per service (DB creds, JWT secret, SES config) | terraform |
| K8S-034 | ExternalSecret per service namespace | k8s |
| APP-001 | order-service publishes `order.placed` event to SQS | k8s |
| APP-002 | notification-service SQS consumer → SES email on `order.placed` | k8s |
| INFRA-018 | Configure SES identity + IAM sending permissions | terraform |
| ARCH-003 | Document saga flow: order create → inventory check → notification | architecture |

### Sprint 12 — Observability + Security Hardening *(2 weeks)*
**Ship Gate:** X-Ray traces span all services, network policies default-deny, canary rollout per service

| Ticket | Title | Label |
|--------|-------|-------|
| OBS-001 | Enable AWS X-Ray tracing per service (or Jaeger via Istio) | observability |
| OBS-002 | Per-service Grafana dashboard (request rate, latency, error rate, SQS depth) | observability |
| OBS-003 | Prometheus AlertManager rules (pod crash, high error rate, SQS dead-letter) | observability |
| K8S-035 | NetworkPolicies per namespace — default deny, explicit ingress allow | security |
| K8S-036 | Pod Security Standards — restricted profile per namespace | security |
| K8S-037 | Convert per-service Deployments to Argo Rollouts (canary per service) | k8s |
| SEC-001 | Run tfsec + Checkov on Phase 3 Terraform — fix all HIGH findings | security |
| SEC-002 | Audit RBAC: service accounts least-privilege, no wildcard permissions | security |

**Phase 3 total: 35 tickets**

---

## Ticket Summary

| Phase | Sprints | Tickets |
|-------|---------|---------|
| Phase 1 — Foundation | 2 × 1wk | 18 |
| Phase 2 — Hardening | 3 × 1wk | 17 |
| Phase 3 — Microservices | 5 × 2wk | 35 |
| **Total** | **~15 weeks** | **70 tickets** |

---

## Open Questions

- [ ] Will mentees have individual AWS accounts or shared sandbox?
- [ ] App code for Phase 3 services — pre-built and handed to mentees, or they scaffold too?
- [ ] PRD format — written doc, slide deck, or live verbal presentation per Epic?
- [ ] Retrospective cadence — end of every sprint or end of every phase?

---

_Brainstorm approved up to full ticket breakdown. Next: write formal spec doc + Jira setup guide._
