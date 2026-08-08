# Architecture Diagram Prompt

This document is a **ready-to-use prompt**, not a narrative doc — paste the whole thing (or the "One-paragraph prompt" section alone) into a diagramming tool, an AI image generator, or a human designer to produce an official-AWS-style architecture diagram of this project. Every fact here is verified against the live AWS account and the Terraform/Kubernetes source as of 2026-08-09, not aspirational — if you change the infra, update this file too or the diagram will drift from reality.

**Style target:** official AWS Architecture Diagram conventions — the look of diagrams on `docs.aws.amazon.com` reference architecture pages. That means:
- Use the real **AWS Architecture Icons** (not generic shapes) for every AWS service — square icon, service name label beneath it, category color per the current AWS icon set (Compute = orange, Database = blue, Networking & Content Delivery = purple, Security/Identity/Compliance = red, Storage = green, Management & Governance = pink/magenta).
- Nest resources inside **boundary boxes**: AWS Cloud (outermost) → Region → VPC → Availability Zone → Subnet. Boundary boxes are labeled, dashed or thin-outlined rectangles, not solid fills.
- Show numbered traffic-flow arrows (①②③…) for at least the primary user request path, matching how AWS numbers request flows in their own reference diagrams.
- Keep a legend if the diagram mixes solid arrows (synchronous HTTP) and dashed arrows (async/background, e.g. GitOps polling, backup replication).

---

## One-paragraph prompt (copy this alone if you just need a quick prompt)

> Generate an AWS official-style architecture diagram for a 3-tier bookstore web application on AWS, region us-west-1 (primary) with us-west-2 as a backup-only DR region. Inside a VPC (CIDR 170.20.0.0/16) spanning two Availability Zones (us-west-1a, us-west-1c), show 2 public subnets (170.20.1.0/24, 170.20.2.0/24) containing an Internet Gateway and a single NAT Gateway, and 6 private subnets: 4 for Amazon EKS worker nodes (170.20.3.0/24 through 170.20.6.0/24) and 2 dedicated to Amazon RDS (170.20.7.0/24, 170.20.8.0/24). Inside the EKS cluster (Amazon EKS, Kubernetes 1.31, managed node group of 3 t3.medium nodes), show 6 Kubernetes namespaces as sub-groupings: bookstore (old monolith frontend), catalog, user, order, notification, and gateway — each running its own Deployment(s). Show a Classic Elastic Load Balancer in front of an NGINX Ingress Controller splitting traffic by hostname to either the frontend Service (static React app) or the api-gateway Service (Node.js, JWT auth), which fans out to catalog-service, user-service, order-service, and notification-service. All services connect to a single Amazon RDS for MySQL instance (Multi-AZ, db.t3.micro) in the RDS-dedicated private subnets, using per-service database schemas. Show Amazon Route 53 in front of the load balancer with a public hosted zone doing active-passive failover routing (backed by a Route 53 health check) plus a private hosted zone for internal RDS DNS. Show AWS Certificate Manager issuing a wildcard TLS cert (DNS validated). Show an optional Amazon CloudFront distribution (drawn dashed/greyed to indicate it's disabled by default) sitting between Route 53 and the load balancer. Show AWS Secrets Manager holding 7 secrets (DB credentials per service, JWT signing secret, Grafana admin password), connected via IAM Roles for Service Accounts (IRSA) to a Kubernetes External Secrets Operator running in the cluster, which syncs them into native Kubernetes Secrets. Show Amazon ECR with 7 repositories (one image per service, plus the legacy frontend/backend). Show a standalone Amazon EC2 instance (t3.small, outside the EKS cluster, in the public subnet) running Prometheus, Grafana, Loki, and Alertmanager via Docker Compose, with a dashed monitoring/metrics-scraping connection back into the EKS cluster. Show AWS IAM with a GitHub OIDC identity provider trust relationship (no static AWS keys), AWS CloudTrail logging to an encrypted Amazon S3 bucket, and Amazon GuardDuty as separate security/governance icons off to one side, each with a light dashed line into the VPC to indicate account-wide monitoring rather than inline traffic. Show Amazon S3 holding Terraform remote state, referenced by a small "Infrastructure as Code" icon labeled Terraform outside the VPC boundary entirely (it's a deployment-time concern, not a runtime component). Number the primary user request flow 1 through 6: (1) user's browser to Route 53, (2) Route 53 to the load balancer, (3) load balancer to NGINX Ingress, (4) Ingress to api-gateway, (5) api-gateway to the appropriate microservice, (6) microservice to RDS.

---

## AWS services to render as icons, grouped by category

Use the exact AWS Architecture Icon for each — these are the real service names, not approximations.

### Compute (orange)
- **Amazon EC2** — the monitoring instance (t3.small) AND the underlying EKS worker node instances (t3.medium × 3) — draw the node group as 3 small EC2 icons inside an "Amazon EKS Managed Node Group" boundary, not as EKS itself (EKS is the control plane / orchestration layer, a separate icon).
- **Amazon Elastic Kubernetes Service (EKS)** — the cluster icon, drawn as a boundary containing the node group and, conceptually, the namespaces/pods running on it.

### Containers
- **Amazon Elastic Container Registry (ECR)** — one icon, labeled with its 7 repositories: `bookstore-frontend`, `bookstore-backend`, `bookstore-catalog-service`, `bookstore-user-service`, `bookstore-order-service`, `bookstore-notification-service`, `bookstore-api-gateway`.

### Database (blue)
- **Amazon RDS** (specifically the MySQL engine icon) — one instance, Multi-AZ, `db.t3.micro`, holding 5 logical schemas (one per service that owns data: the old monolith's schema, `catalog_db`, `user_db`, `order_db`, `notification_db` — `notification-service` itself is stateless/schema-less, it only sends notifications).

### Networking & Content Delivery (purple)
- **Amazon VPC** — the outer boundary, CIDR `170.20.0.0/16`.
- **Internet Gateway** — one, in a public subnet.
- **NAT Gateway** — one (deliberately single, not one-per-AZ — a documented cost tradeoff, not an oversight; label it "single NAT — no per-AZ redundancy" if the diagram has room for callouts).
- **Elastic Load Balancing** — specifically the **Classic Load Balancer** icon (verified live via `aws elb describe-load-balancers` — it is NOT an NLB or ALB, despite what older docs on this project used to say). Provisioned automatically by the in-cluster NGINX Ingress Controller, not by Terraform directly.
- **Amazon Route 53** — two hosted zones: a public one (`<domain>`, active-passive failover routing tied to a health check) and a private one (internal RDS DNS resolution, VPC-scoped).
- **Amazon CloudFront** — draw this dashed/greyed with a note "optional, off by default" — it's real Terraform code (`cloudfront.tf`) but not deployed in the default configuration.
- **AWS Certificate Manager (ACM)** — one wildcard cert, DNS-validated, feeding both the Classic ELB (TLS termination via cert-manager + Let's Encrypt inside the cluster, not ACM directly — ACM's cert here is provisioned for CloudFront's benefit specifically, since CloudFront requires an ACM cert in `us-east-1`) and cert-manager's own Let's Encrypt `ClusterIssuer` (the certs actually terminating TLS at the ingress are Let's Encrypt, issued in-cluster — don't conflate the two certificate sources in the diagram; a small note distinguishing "ACM cert: for optional CloudFront" vs "Let's Encrypt cert: terminates TLS at the real ingress" avoids a common mistake here).

### Security, Identity & Compliance (red)
- **AWS Identity and Access Management (IAM)** — multiple roles exist; the diagram-worthy ones are: the GitHub OIDC role (`bookstore-github-oidc-role`, trust policy scoped to this repo's OIDC provider, used by CI — no static AWS keys anywhere), the EKS cluster/node roles, the External Secrets Operator's IRSA role (`bookstore-external-secrets`), and the monitoring EC2's instance role (`bookstore-monitoring-ec2`, has a read-only EKS access entry).
- **AWS Secrets Manager** — 7 secrets under the `/bookstore/*` path: `db-credentials`, `catalog-db-credentials`, `user-db-credentials`, `order-db-credentials`, `notification-db-credentials`, `jwt-secret`, `grafana-admin`.
- **AWS CloudTrail** — one multi-region trail, logging to an encrypted, versioned S3 bucket (`bookstore-cloudtrail-<account-id>`).
- **Amazon GuardDuty** — one detector, account-wide (S3, Kubernetes audit logs, EBS malware scanning). Draw as an icon off to the side with a light dashed line into the account boundary — it's a monitoring/detection service, not something in the request path.

### Storage (green)
- **Amazon S3** — two buckets worth showing: `bookstore-terraform-state-<account-id>` (Terraform remote state, outside the VPC, a deployment-time concern) and `bookstore-cloudtrail-<account-id>` (CloudTrail log destination, referenced from the CloudTrail icon rather than drawn separately if space is tight).
- **Amazon EBS** — implicit, backing the EKS nodes' root volumes and any dynamic `PersistentVolumeClaim`s (via the EBS CSI driver) — usually omitted from a top-level diagram unless specifically illustrating storage, since it's not a distinct architectural decision point here.

### Management & Governance (pink/magenta)
- **Amazon CloudWatch** — implicit (enhanced RDS monitoring, VPC Flow Logs destination) — small icon, not a focal point.
- Not an AWS service, but worth its own icon/box since it's architecturally significant: **Prometheus + Grafana + Loki + Alertmanager**, self-hosted via Docker Compose on the standalone EC2 instance described under Compute above. Label this box clearly as "self-hosted, not a managed AWS service" so it doesn't get mistaken for Amazon Managed Prometheus/Grafana.

---

## Boundary structure (outermost to innermost)

```
AWS Cloud
└── Region: us-west-1 (primary — all live workloads)
    │   (us-west-2 exists too, DR-only: ECR image replication + RDS automated-
    │    backup replication + a Route 53 failover record — no compute there.
    │    Draw as a small, mostly-empty region box off to the side, not a
    │    mirror of us-west-1 — there is currently nothing to fail over to.)
    │
    └── VPC: 170.20.0.0/16
        │
        ├── Availability Zone: us-west-1a
        │   ├── Public Subnet 170.20.1.0/24   — Internet Gateway, Classic ELB ENI, monitoring EC2
        │   ├── Private Subnet 170.20.3.0/24  — EKS worker nodes
        │   ├── Private Subnet 170.20.5.0/24  — EKS worker nodes
        │   └── Private Subnet 170.20.7.0/24  — RDS (primary AZ)
        │
        └── Availability Zone: us-west-1c
            ├── Public Subnet 170.20.2.0/24   — Internet Gateway, Classic ELB ENI
            ├── Private Subnet 170.20.4.0/24  — EKS worker nodes
            ├── Private Subnet 170.20.6.0/24  — EKS worker nodes
            └── Private Subnet 170.20.8.0/24  — RDS (standby AZ, Multi-AZ)
```

Inside the EKS cluster (drawn as its own labeled region within the private-subnet area, since it logically spans both AZs' node subnets), show these Kubernetes namespaces as sub-boxes:

| Namespace | Contains | Reachable from outside? |
|---|---|---|
| `bookstore` | Old monolith: `frontend` Deployment (static React, still serves the app's HTML/JS/CSS) + `backend` Argo Rollout (Node/Express API — **still running but has zero Ingress routes, unreachable from outside**) | Only `frontend`, via `bookstore.<domain>` |
| `catalog` | `catalog-service` — books CRUD | Only via `api-gateway`, never directly |
| `user` | `user-service` — auth/JWT, register/login | Only via `api-gateway`, never directly |
| `order` | `order-service` — cart, checkout, order history | Only via `api-gateway`, never directly |
| `notification` | `notification-service` — called internally by `order-service` | Never — no ingress, no gateway route either |
| `gateway` | `api-gateway` — the sole public entry point for every API call the frontend makes | Yes, via `api.bookstore.<domain>` |
| `argocd` | ArgoCD (GitOps controller) | Internal only (or via `kubectl port-forward` for admin access) |
| `external-secrets`, `cert-manager`, `ingress-nginx` | Cluster add-ons | Internal only |

---

## Numbered request-flow callouts (for the diagram's arrows)

**Flow A — loading the app (static assets):**
1. Browser → Route 53 (`bookstore.<domain>`)
2. Route 53 → (CloudFront, if enabled) → Classic ELB
3. Classic ELB → NGINX Ingress Controller → `frontend` Service (namespace `bookstore`)
4. Static HTML/JS/CSS returned to browser

**Flow B — every API call the loaded app makes (login, browse, cart, checkout, orders):**
1. Browser → Route 53 (`api.bookstore.<domain>`)
2. Route 53 → (CloudFront, if enabled) → Classic ELB
3. Classic ELB → NGINX Ingress Controller → `api-gateway` Service (namespace `gateway`)
4. `api-gateway` verifies JWT (for writes; reads on `/books` are public) and proxies to the right microservice
5. Microservice → RDS (its own schema, shared instance)
6. Response flows back through the same path

**Flow C — secrets (background, not user-triggered, draw dashed):**
1. AWS Secrets Manager (`/bookstore/*`)
2. → IRSA (IAM role assumed via the cluster's OIDC provider) →
3. External Secrets Operator (namespace `external-secrets`)
4. → `ClusterSecretStore` → per-namespace `ExternalSecret` → native Kubernetes `Secret`
5. Mounted into pod environment variables

**Flow D — GitOps deploy (background, draw dashed):**
1. Developer pushes to `observability` (or `main`)
2. GitHub Actions CI builds, scans (Trivy), pushes image to ECR
3. CI commits a new image tag to `k8s/overlays/prod/kustomization.yaml` (or the relevant service's overlay)
4. ArgoCD polls the git repo every 3 minutes, detects the change
5. ArgoCD applies the new manifest, triggering a rolling update in the cluster

**Flow E — monitoring (background, dashed):**
1. `node-exporter` + `Fluent Bit` (systemd services on every EKS node) expose metrics/logs
2. Standalone monitoring EC2 (Prometheus) scrapes node-exporter targets + `kube-state-metrics` (a Docker container on the same EC2, reading the cluster over the network via a read-only EKS access entry)
3. Grafana (same EC2) queries Prometheus + Loki for dashboards

---

## Things to get right (common mistakes when a diagram is generated from a vague prompt)

- **Not an NLB or ALB — a Classic ELB.** This project's docs used to say NLB everywhere; it's actually a Classic Load Balancer, because the EKS in-tree cloud provider defaults to it when no `aws-load-balancer-type` annotation is set. Verified live via AWS CLI. Get this right or the diagram will show the wrong icon shape (NLB and Classic ELB have visually distinct AWS icons).
- **The old backend is not "the legacy path for some traffic."** It has literally zero ingress routes. Every single frontend API call goes through `api-gateway`. Don't draw a line from `frontend` to `backend-service` — that line doesn't exist anymore.
- **CloudFront is off by default.** Don't draw it as an active part of the path unless explicitly noting it's the optional/disabled configuration.
- **us-west-2 has no compute.** Don't draw a mirrored EKS cluster there — DR today is backup-replication-only (ECR + RDS snapshots + a Route 53 failover record with nothing healthy to fail over to yet).
- **RDS is one instance with 5 schemas, not 5 separate database instances.** Per-service database *isolation* here means schema + user isolation within one shared RDS instance — a deliberate, documented non-goal to run separate RDS instances per service at this stage.
- **The monitoring stack (Prometheus/Grafana/Loki/Alertmanager) is not inside the EKS cluster.** It runs on a separate, plain EC2 instance via Docker Compose — the cluster itself runs zero monitoring pods (a resource-constraint decision, not a preference).

## Related

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — the narrative version of everything summarized here
- [`TERRAFORM.md`](TERRAFORM.md) — every module in depth
- [`KUBERNETES.md`](KUBERNETES.md) — manifests and GitOps wiring
- [`CICD_DIAGRAM_PROMPT.md`](CICD_DIAGRAM_PROMPT.md) — the companion prompt for the CI/CD pipeline diagram
