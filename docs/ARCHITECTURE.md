# Architecture

Current state of the `observability` branch. This describes what the code actually builds, not an aspirational design.

## What this is

A bookstore web app built as a learning/reference implementation of a production-grade AWS three-tier architecture, now mid-migration to a microservices split. Two things are true at once right now:

1. The **original monolith** (`client/` React frontend + `backend/` Node/Express API + RDS MySQL) is the thing that has actually been deployed and tested end-to-end, and still owns production traffic.
2. The **microservices platform** is now fully built: all 5 services (`catalog-service`, `user-service`, `order-service`, `notification-service`, `api-gateway`) are implemented, tested, and registered with ArgoCD, per [`docs/superpowers/specs/2026-07-29-microservices-observability-design.md`](superpowers/specs/2026-07-29-microservices-observability-design.md) and [Plans 1-4](#related), and the frontend has a real login/cart/checkout/orders UI wired to it (see [Plan 5](#related)). `backend/` and `k8s/base/` still exist and still serve `bookstore.<domain>` (frontend static assets) — the full monolith retirement described in Plan 4 Task 9 hasn't happened — but the ingress host collision that used to block `api.bookstore.<domain>` traffic from reliably reaching the gateway is **resolved**: `k8s/base/ingress/ingress.yaml` no longer declares that host at all, `k8s/services/api-gateway/base/ingress.yaml` is its sole owner, and every write to `/books` now genuinely requires the JWT the gateway enforces (verified live — `POST /books` without a token returns `401`, confirming the old backend isn't answering that host anymore).

## Top-level system diagram (current, monolith serving traffic)

```
                                   Internet
                                      |
                         Route53 (public zone, failover routing)
                                      |
                    ┌─────────────────────────────────┐
                    │   CloudFront (optional, off by   │
                    │   default) or direct to NLB      │
                    └─────────────────────────────────┘
                                      |
                              Nginx Ingress (NLB)
                                      |
                    ┌─────────────────┴─────────────────┐
                    |                                     |
              frontend Service                      backend Service
              (React static, nginx)              (Node/Express, Argo Rollout canary)
                                                          |
                                                    RDS MySQL 8.0
                                                    (Multi-AZ, us-west-1)
```

Everything above lives in one EKS cluster (`bookstore-eks`, us-west-1), one `bookstore` namespace, deployed via ArgoCD from `k8s/overlays/prod`.

## Region layout

**Primary: us-west-1** — all live workloads (EKS, RDS, monitoring EC2, all traffic).
**Secondary: us-west-2** — DR only. ECR image replication + RDS automated-backup replication (needs an explicit KMS key, off by default) + a Route53 failover record. **No EKS cluster in us-west-2.** If us-west-1 goes down, there's no compute to fail over to yet — DR today is backup-level, not active-active. See [`dr.tf`](../dr.tf).

## Terraform module graph

`network → security → acm → rds → route53 → ecr → eks → eks-addons → monitoring-ec2` is the module *call* order in `main.tf`, but that's not the real dependency graph — Terraform parallelizes anything not actually connected by a resource/output reference, regardless of where it's written in the file. The real shape:

```
network ──┬─→ security ──┬─→ rds ──→ route53
          │              └─→ eks ──┬─→ eks-addons ─────┐
          │                        └─→ monitoring-ec2 ←┘ (needs eks + the
acm (independent)                                         eks-addons Grafana
ecr  (independent)                                         secret only, not
iam.tf / cloudtrail.tf / guardduty.tf (independent)         any Helm install)
```

`acm`, `ecr`, and the root `iam.tf`/`cloudtrail.tf`/`guardduty.tf` resources have no dependency on `network` at all and run fully in parallel with it. `rds` and `eks` both depend only on `network`+`security`, not on each other, so they provision concurrently — this is why a full stand-up takes roughly `max(RDS time, EKS time)` for that stage, not the sum. `monitoring-ec2` used to have a blanket `depends_on = [module.eks_addons]` forcing it to wait for every Helm chart in `eks-addons` (up to 900s for ArgoCD) even though it only needs the fast Grafana secret — that's been removed; see [`TERRAFORM.md`](TERRAFORM.md#module-monitoring-ec2). Full detail on what runs when: [`TERRAFORM.md`](TERRAFORM.md).

| Module | Creates | Depends on |
|---|---|---|
| `network` | VPC `170.20.0.0/16`, 2 public + 6 private subnets, IGW, single NAT gateway, VPC Flow Logs | — |
| `security` | Security groups: ALB (80/443 from internet), RDS (3306 from VPC CIDR) | `network` |
| `acm` | Wildcard ACM cert (DNS validation) for the ingress domain | — |
| `rds` | MySQL 8.0 `db.t3.micro`, Multi-AZ, Secrets Manager admin credentials, enhanced monitoring, optional cross-region backup replication | `network`, `security` |
| `route53` | Private zone (RDS internal DNS) + public zone with active-passive failover records | `network`, `rds`, `eks` (needs ALB DNS) |
| `ecr` | ECR repos for `frontend`, `backend`, plus any `extra_repos` (currently `catalog-service`, `user-service`, `order-service`, `notification-service`, `api-gateway`), 10-image lifecycle policy, optional cross-region replication | — |
| `eks` | EKS 1.31 cluster, managed node group (`t3.medium`, min 1 / max 2 / desired 2), OIDC provider (enables IRSA), node launch template running node-exporter + Fluent Bit as systemd services | `network`, `security` |
| `eks-addons` | Helm-installed cluster add-ons: cert-manager, External Secrets Operator, ingress-nginx, ArgoCD, Argo Rollouts, EBS CSI driver | `eks` |
| `monitoring-ec2` | Standalone EC2 (`t3.small`) running Prometheus + Grafana + Loki + Alertmanager + kube-state-metrics via Docker Compose | `network`, `eks-addons` |

Root-level `.tf` files add cross-cutting resources not owned by any module: `iam.tf` (GitHub OIDC role for CI), `cloudtrail.tf` (multi-region trail, encrypted S3), `guardduty.tf` (S3/K8s-audit/EBS-malware detection), `cloudfront.tf` (optional CDN, ACM cert in us-east-1), `dr.tf` (cross-region backup replication). Full detail: [`TERRAFORM.md`](TERRAFORM.md).

## Why monitoring runs on EC2, not in the cluster

The original design put `kube-prometheus-stack` in EKS. On a single `t3.medium` node it starved every other pod pulling images and never became `Ready` within any reasonable Helm timeout (see [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) TF-001/TF-006). The fix: move Prometheus, Grafana, Loki, and Alertmanager to a dedicated EC2 instance running Docker Compose. The EKS cluster itself runs **zero monitoring pods** — `node-exporter` and `Fluent Bit` run as systemd services baked into the node launch template instead of DaemonSets, and `kube-state-metrics` runs as a Docker container on the monitoring EC2, reading the cluster over the network via a read-only EKS access entry.

`k8s/base/monitoring/` still has `ServiceMonitor`/`PrometheusRule` CRD manifests in the repo. **These are effectively inert** — nothing installs the Prometheus Operator that would consume them, and the EC2 Prometheus scrapes via static configs and `file_sd_configs` (a cron script rewriting target files), not via `ServiceMonitor` discovery. Don't assume applying them does anything; see [Known Issues in TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## The database

Single RDS MySQL 8.0 instance, `db.t3.micro`, Multi-AZ, in two private subnets dedicated to RDS (subnet indices 4-5 of the 6 private subnets — see [Subnet layout](#subnet-layout)). Admin credentials live in Secrets Manager at `/bookstore/db-credentials`, synced into the cluster as a K8s Secret via External Secrets Operator.

`k8s/base/database/mysql-statefulset.yaml`, `mysql-service.yaml`, and `mysql-init-configmap.yaml` still exist on disk but are **not** in `k8s/base/kustomization.yaml`'s resource list — dead files from an earlier design where MySQL ran in-cluster. RDS is the real, only database.

## Secrets flow (and the bug that used to break it)

```
AWS Secrets Manager (/bookstore/*)
        |
        | IRSA (IAM Role for Service Account)
        v
External Secrets Operator (external-secrets-sa, namespace external-secrets)
        |
        | ClusterSecretStore "aws-secretsmanager" (cluster-scoped, shared)
        v
ExternalSecret (per namespace, e.g. db-secret, catalog-db-secret)
        |
        v
K8s Secret → mounted into pod env vars
```

Until commit `b48c3d3` on this branch, **this entire chain was broken**: the External Secrets Operator's Helm release created a ServiceAccount with no IRSA role and no annotation, even though the `ClusterSecretStore` already expected one named exactly `external-secrets-sa`. No ExternalSecret anywhere in the cluster — old or new — could actually pull from Secrets Manager. Fixed in `modules/eks-addons/external-secrets.tf` (IRSA role + trust policy, Helm release now names and annotates the ServiceAccount correctly). Full story in [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).

The `ClusterSecretStore` + shared IRSA role is **cluster-wide**, scoped in IAM to `/bookstore/*`. Every service's `ExternalSecret` — old `db-secret` and every future microservice's own secret — reuses the same role. This is a deliberate simplification: true per-service secret isolation would need per-namespace `SecretStore` objects instead of one shared `ClusterSecretStore`, which is more machinery than this project's current stage justifies.

## GitOps / deployment flow

```
git push → GitHub Actions CI
  1. secret-scan (Gitleaks)
  2. sast (Semgrep, npm audit, unit tests)          ┐
     validate (ESLint, kubeconform)                  ├─ parallel
  3. build-and-push (Docker build → Trivy scan → ECR push)
  4. deploy (main branch only, manual approval gate):
       kustomize edit set image ... → commit → push
                    |
                    v
            ArgoCD polls repo every 3 min
                    |
                    v
        kustomize build k8s/overlays/prod
                    |
                    v
          reconciles cluster (auto-prune, self-heal)
```

CI never runs `kubectl` directly — it only edits image tags in git, and ArgoCD does the actual apply. Full detail: [`CICD.md`](CICD.md).

## The microservices platform (built, not yet live)

All 5 services are implemented and registered with ArgoCD:

```
frontend (React)
    |  HTTP (not yet pointed here — see below)
api-gateway (Node/Express + http-proxy-middleware, JWT verification)   — done
    ├── /books        → catalog-service        — done
    ├── /auth,/users   → user-service           — done
    ├── /orders        → order-service          — done
    └── (internal)     → notification-service    — done, called by order-service
```

Each service: own ECR repo, own K8s namespace, own Deployment/Service/HPA/PDB, own schema inside the *same* shared RDS instance (schema-level isolation, not per-service RDS — that's an explicit non-goal for now), own `/metrics` endpoint labeled `service="<name>"`. Deployed via a single ArgoCD `ApplicationSet` (`k8s/argocd/applicationset-microservices.yaml`) with a list generator, now listing all 5 services.

`catalog-service`/`user-service`/`order-service`'s `NetworkPolicy`s were tightened once `api-gateway` existed — ingress is now scoped to the `gateway` namespace instead of allowing all traffic (see commit `153bed2`). `api-gateway` has a real public `Ingress` (`k8s/services/api-gateway/base/ingress.yaml`) for `api.bookstore.<domain>`, and it's now the sole claimant of that host — `k8s/base/ingress/ingress.yaml`'s duplicate rule was removed as part of building the frontend's login/cart/checkout UI (see [Plan 5](#related)), which needed the gateway to be reliably reachable rather than winning by undefined nginx tie-breaking.

Explicitly deferred (see the design spec's Non-goals): service mesh / mTLS, async messaging (SQS), per-service RDS instances, distributed tracing, NetworkPolicy hardening beyond what's described above.

## Subnet layout

```
VPC 170.20.0.0/16 (us-west-1)

public[0]   170.20.1.0/24   us-west-1a   — IGW, NLB
public[1]   170.20.2.0/24   us-west-1c   — IGW, NLB
private[0]  170.20.3.0/24   us-west-1a   — EKS nodes
private[1]  170.20.4.0/24   us-west-1c   — EKS nodes
private[2]  170.20.5.0/24   us-west-1a   — EKS nodes
private[3]  170.20.6.0/24   us-west-1c   — EKS nodes
private[4]  170.20.7.0/24   us-west-1a   — RDS
private[5]  170.20.8.0/24   us-west-1c   — RDS
```

Single NAT gateway in `public[0]` — a deliberate cost tradeoff for a demo/reference project. Production would want one NAT per AZ.

## Traffic flow (monolith, current production path)

```
Internet → Route53 → (CloudFront, optional) → Nginx Ingress NLB
    → frontend Service (static React via nginx)
    → backend Service (Argo Rollout, canary 10%→25%→50%→100%)
    → RDS :3306
```

## Related docs

- [`TERRAFORM.md`](TERRAFORM.md) — every module, in depth
- [`KUBERNETES.md`](KUBERNETES.md) — manifests, Kustomize layout, ArgoCD
- [`CICD.md`](CICD.md) — the GitHub Actions pipeline
- [`DEPLOYMENT.md`](DEPLOYMENT.md) — how to actually stand this up
- [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) — real errors hit and how they were fixed
- [`FUTURE_IMPROVEMENTS.md`](FUTURE_IMPROVEMENTS.md) — what's next
- [design spec](superpowers/specs/2026-07-29-microservices-observability-design.md) — the microservices platform design
- [Plan 1](superpowers/plans/2026-07-30-catalog-service.md) — catalog-service implementation plan (done)
- [Plan 2](superpowers/plans/2026-08-01-user-service.md) — user-service implementation plan (done)
- [Plan 3](superpowers/plans/2026-08-01-order-notification-service.md) — order-service + notification-service implementation plan (done)
- [Plan 4](superpowers/plans/2026-08-01-api-gateway.md) — api-gateway implementation plan (done; final cutover/backend-deletion task paused, not executed)
- [Plan 5](superpowers/plans/2026-08-08-frontend-microservices-integration.md) — login/cart/checkout/orders UI + the ingress collision fix (done)
