# What's Actually Running — Nodes, Pods, and Why Each One Exists

This is a snapshot, not a living doc — captured 2026-08-15 against the live `bookstore-eks` cluster, right after the ALB migration and JWT refresh-token work landed. Pod counts, ages, and IPs will drift the moment anything redeploys or the HPAs react to load; the *shapes* (which namespaces exist, why each Deployment is there, why replica counts differ) are the part meant to stay true. Re-run the commands under each section to get today's real numbers.

## Part 0: Two different kinds of "node" — don't conflate them

There are **4 real compute instances** behind this stack, but only 3 of them are Kubernetes nodes:

| # | What | Instance type | Managed by | Runs |
|---|---|---|---|---|
| 1-3 | EKS worker nodes | `t3.medium` (2 vCPU / 4 GiB each) | `module.eks`'s managed node group, `min=1 / desired=3 / max=3` | every pod listed below |
| 4 | Monitoring box | `t3.small` (2 vCPU / 2 GiB) | `module.monitoring-ec2`, plain EC2, **not** part of the EKS cluster | Prometheus, Grafana, Alertmanager, Loki, Fluent Bit — via Docker Compose, not Kubernetes (see `ARCHITECTURE.md`'s "monitoring moved off-cluster" section) |

```bash
kubectl get nodes -L node.kubernetes.io/instance-type,topology.kubernetes.io/zone
```

**Why 3 EKS nodes, not 1 or 5:** `3 × 2 vCPU (EKS) + 1 × 2 vCPU (monitoring) = 8 vCPU` — this is the literal ceiling from the OBS-054 FinOps pass ("fix: FinOps + standards audit fixes within the 8-vCPU ceiling"). Every infra decision on this branch after that commit was explicitly constrained to never need that quota raised. 3 nodes (not 1) also spreads pods across 2 availability zones (`us-west-1a`, `us-west-1c` in the snapshot above) — real fault tolerance, not just headroom: a Multi-AZ `PodDisruptionBudget` or a `topologySpreadConstraint` is meaningless with only one AZ to spread across.

**Why `t3.medium` specifically:** see `KUBERNETES_EXPLAINED.md` Part 7 for the exact ENI-IP-address math, but the short version is this instance size caps out in the high teens of schedulable pods per node — comfortably above what this cluster actually runs (36 pods ÷ 3 nodes ≈ 12 average), with room for an HPA to scale a service up without instantly hitting a node's pod-IP ceiling.

## Part 1: Every pod, grouped by *why it exists*, not just by namespace

```bash
kubectl get pods -A -o wide
```

### Cluster plumbing — exists because EKS needs it to function at all, not because this app chose it

| Namespace | Pod(s) | Count | Why |
|---|---|---|---|
| `kube-system` | `aws-node` | 1 per node (DaemonSet) | The VPC CNI — gives every pod a real, routable VPC IP instead of an overlay network. Without this, no pod on that node gets networking at all. |
| `kube-system` | `kube-proxy` | 1 per node (DaemonSet) | Programs each node's iptables/IPVS rules so a `Service`'s ClusterIP actually load-balances to the right pod `Endpoints` — see `KUBERNETES_EXPLAINED.md` Part 7 for the exact DNAT mechanics. |
| `kube-system` | `coredns` | 2 | Cluster-internal DNS — `catalog-service.catalog.svc.cluster.local`-style names only resolve because this exists. 2 replicas so DNS itself isn't a single point of failure. |
| `kube-system` | `ebs-csi-controller` | 2 | Provisions/attaches EBS volumes when a `PersistentVolumeClaim` needs one. Nothing in this app-tier actually uses one today (RDS is external, not in-cluster — see the OBS-era MySQL-removal work), but it's a default EKS add-on and other cluster-scoped things (ArgoCD's Redis, if configured with persistence) could. |
| `kube-system` | `ebs-csi-node` | 1 per node (DaemonSet) | The per-node half of the same CSI driver — mounts the volume `ebs-csi-controller` provisioned onto whichever node the consuming pod actually landed on. |
| `kube-system` | `metrics-server` | 2 | Answers `kubectl top` and, more importantly, is what every `HorizontalPodAutoscaler` in this cluster actually queries for live CPU/memory numbers — delete this and every HPA silently stops scaling, with no obvious error. |
| `kube-system` | `aws-load-balancer-controller` | 2 | Watches `Ingress` objects annotated `ingressClassName: alb` and provisions/reconciles the real ALB in AWS — see OBS-057. Everything under "Application tier" below reaches the internet through what this controller manages. |

### Platform / GitOps — exists to deploy and secure everything else, not itself part of the "bookstore" product

| Namespace | Pod(s) | Count | Why |
|---|---|---|---|
| `argocd` | `argocd-application-controller` | 1 (StatefulSet) | The actual reconcile loop — diffs live cluster state against git and applies the difference. Everything in "Application tier" below exists because this pod put it there. |
| `argocd` | `argocd-applicationset-controller` | 1 | Expands `applicationset-microservices.yaml`'s `list` generator into the 5 per-service `Application` objects — see `KUBERNETES_EXPLAINED.md` Part 8 for the full execution-order walkthrough. |
| `argocd` | `argocd-repo-server` | 1 | Clones the git repo and runs `kustomize build` against whatever path an `Application` points at — the thing that actually turns `k8s/services/catalog-service/overlays/prod` into real YAML. |
| `argocd` | `argocd-server` | 1 | The API server / UI — what `argocd` CLI and the web dashboard both talk to. |
| `argocd` | `argocd-dex-server` | 1 | SSO/auth broker for the ArgoCD UI — present even though this project doesn't currently wire up an external identity provider, since it's part of the default ArgoCD Helm chart. |
| `argocd` | `argocd-redis` | 1 | Cache layer the other ArgoCD components share, mainly for repo-server's rendered-manifest cache — avoids re-running `kustomize build` on every single reconcile tick. |
| `argocd` | `argocd-notifications-controller` | 1 | Watches `Application` health/sync-status changes and fires configured notifications (Slack/email/webhook) — dormant unless a notification template is actually configured. |
| `argo-rollouts` | `argo-rollouts` | 1 | The canary-deployment controller — drives progressive rollouts for any `Rollout` object (Argo Rollouts' own CRD, a drop-in replacement for a plain `Deployment` with traffic-shifting steps). |
| `external-secrets` | `external-secrets` | 1 | The core ESO controller — reconciles every `ExternalSecret` object cluster-wide against AWS Secrets Manager, on the interval each one specifies (`1h` for this project's `admin-db-secret`s). |
| `external-secrets` | `external-secrets-webhook` | 1 | Validates `ExternalSecret`/`ClusterSecretStore` objects at admission time — catches a malformed one before it's even stored, not just at the next reconcile. |
| `external-secrets` | `external-secrets-cert-controller` | 1 | Manages the TLS certificate the webhook above uses to talk to the Kubernetes API server over HTTPS — a small, easy-to-forget dependency of the webhook existing at all. |

### Application tier — the actual product, "bookstore"

| Namespace | Pod(s) | Replicas | Why this many |
|---|---|---|---|
| `bookstore` | `frontend` | 2 | React SPA, served as static assets. 2 replicas is the `HorizontalPodAutoscaler`'s `minReplicas` (`frontend-hpa`: min 1, max 3, but the Deployment's own `replicas: 2` sets the floor ArgoCD syncs to) — public-facing, so it never runs at a single point of failure even at idle traffic. |
| `gateway` | `api-gateway` | 2 | Every authenticated request from the frontend passes through this — same "never single-instance" reasoning as frontend, reinforced by its `PodDisruptionBudget`. Its HPA (`api-gateway-hpa`) has the widest range in the cluster, `min 2 / max 8`, because it's the one component every other service's traffic funnels through. |
| `catalog` | `catalog-service` | 1 | Public book-catalog reads — genuinely the lowest-criticality service (read-only, no auth, easily retried by a client), so it's the one place this project accepted single-replica risk to stay inside the 8-vCPU budget. Its HPA can scale to 5 under real load. |
| `user` | `user-service` | 1 | Auth/JWT issuance + the refresh-token rotation added this session. Single replica today for the same budget reason as catalog — worth revisiting first if this project's traffic ever became real, since this is the one service an outage of directly blocks every other authenticated action. |
| `order` | `order-service` | 1 | Cart + checkout + order history. |
| `notification` | `notification-service` | 1 | Order-status notifications (see `docs/ARCHITECTURE.md` for exactly what it sends and to where). |

```bash
kubectl get deployments -A
kubectl get hpa -A
```

## Part 2: The totals, and where the "why this many pods" question actually gets decided

```bash
kubectl get pods -A --no-headers | wc -l
```

36 pods today, roughly: **19 cluster-plumbing/platform pods that exist regardless of what this app is** (CNI, DNS, proxy, storage, autoscaling, GitOps, secrets, ALB controller — Part 1's first two tables), and **8 application-tier pods that are "the product"** (frontend ×2, api-gateway ×2, catalog/user/order/notification ×1 each) — the rest of the 36 is the DaemonSet multiplication (`aws-node`/`kube-proxy`/`ebs-csi-node`, 3 nodes each) plus a couple of 2-replica system Deployments (`coredns`, `ebs-csi-controller`, `metrics-server`, `aws-load-balancer-controller`).

The replica-count *decisions* — not just the current numbers — live in three places, in order of authority:

1. Each Deployment's own `replicas:` field (`k8s/base/frontend/deployment.yaml`, `k8s/services/<name>/base/deployment.yaml`) — the floor ArgoCD's `selfHeal` continuously enforces.
2. Each service's `HorizontalPodAutoscaler` (`k8s/base/.../hpa-frontend.yaml`, `k8s/services/<name>/base/hpa.yaml`) — the *ceiling* and the live-scaling behavior above the floor, driven by `metrics-server`'s numbers.
3. This project's 8-vCPU FinOps ceiling (OBS-054) — the reason every one of these numbers is as low as it is in the first place, not "1 replica because it doesn't matter," but "1 replica because that's what fits."

## Related

- [`KUBERNETES_EXPLAINED.md`](KUBERNETES_EXPLAINED.md) — what each manifest actually does, and (Part 8) the full execution order that puts these pods here
- [`ARCHITECTURE_EXPLAINED.md`](ARCHITECTURE_EXPLAINED.md) — why monitoring lives off-cluster on its own EC2 instead of in-cluster
- [`TERRAFORM_EXPLAINED.md`](TERRAFORM_EXPLAINED.md) — the node group, `eks-addons`, and monitoring-EC2 Terraform resources that create the infrastructure this doc is a snapshot of
- `../docs/TROUBLESHOOTING.md` OBS-054 — the 8-vCPU ceiling this entire pod/replica budget is built around
