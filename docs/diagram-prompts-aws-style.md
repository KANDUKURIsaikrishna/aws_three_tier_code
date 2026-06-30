# Architecture Diagram Prompts — AWS Official Style

All prompts in this file follow the **AWS Architecture Diagram Standards**:
- Icons from the [AWS Architecture Icons pack](https://aws.amazon.com/architecture/icons/) (download and use in draw.io, Lucidchart, Cloudcraft)
- AWS grouping shapes: AWS Cloud border (light grey) → Region box (light blue border) → VPC box (green border) → AZ box (blue dashed border) → Subnet (grey/green fill)
- AWS colour coding: orange = compute/containers, blue = networking, green = storage/database, purple = security, red = management/governance, white = application services
- Arrow conventions: solid line = data/traffic flow, dashed line = management/control plane, thick arrow = replication
- All service boxes use AWS official service icon (top-left of box) + service name below icon

**Best tools to use these prompts:**
- [draw.io](https://app.diagrams.net) → Extras → Edit Diagram → paste XML, or use AWS shape library (Search: AWS)
- [Cloudcraft](https://www.cloudcraft.co) — native AWS icons, drag-and-drop
- [Lucidchart](https://lucidchart.com) → AWS shape library template
- [Eraser.io](https://eraser.io) → "Diagram from prompt" tab → paste prompt directly

---

## Diagram 1 — Full System Architecture (Primary Region)

**Tool:** draw.io with AWS19 icon pack | **Format:** PNG/SVG | **Orientation:** Portrait

### Prompt

```
Create an AWS architecture diagram in official AWS style for a three-tier bookstore 
application deployed on EKS in us-west-1 (N. California).

ICONS: Use official AWS Architecture Icons for every service:
  - Amazon Route 53 icon for DNS
  - Amazon CloudFront icon for CDN
  - Elastic Load Balancing (Network) icon for NLB
  - Amazon EKS icon for Kubernetes cluster
  - Amazon ECR icon for container registry
  - Amazon RDS icon for database
  - AWS Secrets Manager icon for secrets
  - AWS Certificate Manager icon for TLS
  - Amazon CloudWatch icon for monitoring/logs
  - AWS CloudTrail icon for audit
  - Amazon GuardDuty icon for threat detection
  - Amazon VPC icon for VPC grouping

GROUPING SHAPES (AWS standard):
  - Outer: "AWS Cloud" rectangle (light grey background, bold AWS orange top border)
  - Inside: "us-west-1" Region rectangle (light blue dashed border, region label top-left)
  - Inside region: "VPC 170.20.0.0/16" rectangle (solid green border)
  - Inside VPC: AZ boxes "us-west-1a" and "us-west-1c" (light blue dashed rectangle)
  - Inside AZ boxes: "Public Subnet" (light green fill) and "Private Subnet" (light blue fill)
  - Kubernetes namespaces: rounded rectangle with small "k8s" label, colour by namespace

LAYOUT (top to bottom):
  
  [External Internet Layer]
  User (person icon) 
  → HTTPS → Route 53 (active/passive failover health check shown as health-check icon)
  → Optional: CloudFront (mark as "enable_cloudfront=true optional")
  Domain registrar NS delegation arrow from registrar → Route53 (dashed)

  [AWS Cloud boundary begins]
  [us-west-1 Region box]
  [VPC 170.20.0.0/16 box]
  
  [Public Subnets row - light green fill]
  ┌─ us-west-1a ──────────────┐  ┌─ us-west-1c ──────────────┐
  │ NAT Gateway icon           │  │ (no NAT - cost optimised)  │
  │ Internet Gateway icon      │  │                            │
  └───────────────────────────┘  └───────────────────────────┘
  Network Load Balancer icon (spans public subnets, provisioned by nginx-ingress)

  [Private Subnets - EKS Nodes - light blue fill]
  Amazon EKS cluster box (t3.medium node group, min 1 max 2)
  Inside EKS box, show Kubernetes namespace rounded rectangles:

    [bookstore namespace - blue border]
      - Frontend pod: nginx icon + "React App :8080, replicas:2, HPA:2-3"
      - Backend pod: node.js icon + "Node.js Express :3000, Argo Rollout canary, HPA:1-5"
      - /metrics endpoint shown on backend pod
    
    [ingress-nginx namespace - orange border]
      - nginx-ingress controller pod
      - Arrow: NLB → ingress-nginx → routes by host to frontend(:8080) / backend(:3000)
    
    [cert-manager namespace - purple border]
      - cert-manager pod + ClusterIssuer (letsencrypt-prod, ACME HTTP-01)
      - Arrow: Ingress annotation → cert-manager → Let's Encrypt CA → k8s TLS Secret
    
    [external-secrets namespace - yellow border]
      - ESO controller pod + ClusterSecretStore (IRSA)
      - Arrow: ESO → Secrets Manager → k8s Secret "db-secret" → backend env vars
    
    [monitoring namespace - green border]
      - Prometheus icon + "ServiceMonitor scrapes backend /metrics"
      - Grafana icon + "admin pwd from SM /bookstore/grafana-admin"
      - Alertmanager icon
      - Loki icon + Promtail DaemonSet icon
      - Arrow: Prometheus → AnalysisTemplate (canary gate)
    
    [argocd namespace - teal border]
      - ArgoCD icon + "polls GitHub every 3 min, applies k8s/overlays/prod/"
    
    [argo-rollouts namespace - red border]
      - Argo Rollouts controller + "canary: 10%→25%→50%→100% via nginx canary-weight"

  [Private Subnets - RDS - light blue fill]
  ┌─ us-west-1a ────────────┐  ┌─ us-west-1c ────────────┐
  │ RDS MySQL 8.0 (PRIMARY)  │  │ RDS MySQL (STANDBY)      │
  │ db.t3.micro, 25GB gp2    │  │ Multi-AZ auto-failover   │
  └──────────────────────────┘  └──────────────────────────┘

  [AWS Managed Services - outside VPC, inside Region box]
  Row of service icons with labels:
  ECR (2 repos, IMMUTABLE) | Secrets Manager (/bookstore/db-credentials, /bookstore/grafana-admin)
  ACM (*.b17facebook.xyz) | CloudWatch (VPC Flow Logs, 90d) | CloudTrail (multi-region S3)
  GuardDuty (EKS+S3+malware) | S3+DynamoDB (Terraform state+lock)

  [External - outside AWS Cloud box]
  GitHub box (top-right):
  - GitHub Actions CI: arrows showing secret-scan→sast→build→Trivy→ECR push
  - OIDC keyless auth arrow → AWS IAM role (label: "no static keys")
  - ArgoCD poll arrow ← GitHub repo kustomization.yaml

CONNECTIONS WITH PORT LABELS:
  User → Route53 → NLB :443
  NLB → ingress-nginx → frontend :8080
  NLB → ingress-nginx → backend :3000
  backend → RDS :3306 (through Security Group - show SG as dashed border)
  backend → Secrets Manager (HTTPS, IRSA)
  EKS nodes → ECR (image pull, HTTPS)
  GitHub Actions → ECR (docker push)

SECURITY ANNOTATIONS:
  Show Security Groups as dashed orange borders:
  - SG-nginx: inbound 443/80 from 0.0.0.0/0
  - SG-eks: inbound 3000/8080 from SG-nginx only
  - SG-rds: inbound 3306 from SG-eks only
  NetworkPolicy: show as purple dashed box around bookstore namespace pods
  Label: "default-deny + allow-listed ingress/egress"

STYLE RULES:
  - White background
  - All icons from official AWS Architecture Icons 2024 pack
  - AWS orange (#FF9900) for borders/highlights
  - Region box: light blue (#E3F2FD) background
  - VPC box: light green (#E8F5E9) border
  - Subnet labels: small grey text top-left of each subnet box
  - Arrow labels: small grey text alongside arrow
  - Font: Arial or Helvetica, 10-12pt for labels
  - Service name below each icon, bold
```

---

## Diagram 2 — Multi-Region Disaster Recovery

**Tool:** draw.io with AWS19 icon pack | **Format:** PNG/SVG | **Orientation:** Landscape (16:9)

### Prompt

```
Create a multi-region AWS architecture diagram in official AWS style showing 
active/passive disaster recovery for the Bookstore application.

ICONS: All official AWS Architecture Icons 2024.

LAYOUT: Landscape. Three columns.

  [TOP ROW - Global services, spanning full width, dark navy background]
  Centre: Route53 icon + "b17facebook.xyz public zone"
          + Health Check icon (label: "HTTPS :443, 30s interval, failure_threshold:3")
  Left of Route53: CloudFront icon + "optional CDN (enable_cloudfront=true)"
  Far right small box: "us-east-1" with ACM icon + "CloudFront ACM cert — AWS hard requirement"

  [MAIN ROW - Two AWS Region boxes side by side]

  LEFT REGION BOX — solid green border, label top:
  "AWS us-west-1 — N. California — 🟢 PRIMARY (Active — 100% traffic)"

    [VPC 170.20.0.0/16 - green border]
    Public Subnets:
      Internet Gateway icon | NAT Gateway icon (us-west-1a only, label: "single NAT")
      Network Load Balancer (NLB) icon — labelled "LIVE TRAFFIC"
    
    Private Subnets EKS:
      EKS cluster box (bookstore-eks, EKS icon)
        - bookstore namespace: frontend pod + backend pod (canary Rollout)
        - monitoring: Prometheus + Grafana + Loki
        - argocd: ArgoCD controller
        - cert-manager, external-secrets, argo-rollouts (compact icons row)
    
    Private Subnets RDS:
      RDS icon (PRIMARY, us-west-1a) ←→ RDS icon (STANDBY, us-west-1c)
      Label: "Multi-AZ, 60-120s auto-failover"
    
    Managed services column (right of VPC):
      ECR icon "SOURCE" | Secrets Manager icon "SOURCE"
      CloudTrail icon | GuardDuty icon

  RIGHT REGION BOX — dashed grey border, label top:
  "AWS us-west-2 — Oregon — 🟡 SECONDARY (Warm Standby)"

    Warm standby (SOLID boxes — exist NOW):
      ECR icon "REPLICA — real-time sync" (solid box)
      Secrets Manager icon "REPLICA — credentials ready" (solid box)
      AWS Backup icon "RDS backups — 7-day retention" (solid box)
    
    On-demand (DASHED boxes — provision on DR event):
      EKS icon (dashed box, label: "deploy on DR event — same Terraform")
      NLB icon (dashed box, label: "provisioned during DR")
      RDS icon (dashed box, label: "restore from backup on DR event")

  [BOTTOM — Failover callout box, centre between regions]
  Numbered sequence box (grey background, orange border):
  "Failover Sequence (Steps 1-2 automatic, 3-7 manual)
   1. Health check fails 3× → 90s elapsed
   2. Route53 auto-flips DNS → SECONDARY record active
   3. Restore RDS from us-west-2 backup
   4. terraform apply — deploy EKS in us-west-2
   5. Update /bookstore/db-credentials in us-west-2 SM with new DB_HOST
   6. set secondary_alb_dns in tfvars → terraform apply
   7. ESO reads SM replica → pods get credentials
   RPO: ~1h | RTO: ~1 day"

  [RTO/RPO TABLE - bottom right corner]
  Small table:
  Scenario          | RPO    | RTO
  Pod crash         | 0      | 30s
  Node failure      | 0      | 2 min
  RDS AZ failover   | 0      | 60-120s
  Region failure    | ~1h    | ~1 day

REPLICATION ARROWS (thick orange, spanning between regions):
  Arrow 1: RDS PRIMARY → us-west-2 backup store
    Label: "aws_db_instance_automated_backups_replication\n7-day retention, daily"
  Arrow 2: ECR us-west-1 → ECR us-west-2
    Label: "aws_ecr_replication_configuration\nPrefix: bookstore-*, real-time"
  Arrow 3: SM us-west-1 → SM us-west-2
    Label: "SM cross-region replication\ncredentials always available"

DNS ARROWS (from Route53):
  Solid arrow → us-west-1 NLB, labelled "FAILOVER PRIMARY ✅ Active"
  Dashed arrow → us-west-2 NLB, labelled "FAILOVER SECONDARY ⏸ Dormant"
  Dashed red arrow from health check fail event → Route53 DNS flip label

STYLE RULES:
  - Landscape 16:9 format
  - Left region: vivid full-colour AWS icons, solid green region border
  - Right region: greyscale icons for on-demand (dashed) components, full colour for warm standby (solid)
  - Replication arrows: thick #FF9900 orange with "ALWAYS ACTIVE" badge
  - Global layer: dark navy (#0D1117) background strip spanning top
  - All AWS official 2024 icons, white background regions
  - Font: Arial 10-12pt
```

---

## Diagram 3 — Secrets & Credentials Flow

**Tool:** Lucidchart or draw.io | **Format:** PNG | **Orientation:** Portrait

### Prompt

```
Create a data-flow diagram in official AWS style showing the complete secrets 
and credentials lifecycle for the Bookstore application.

ICONS: AWS official icons for: Terraform (HashiCorp), Secrets Manager, 
EKS (Kubernetes), RDS, IAM, Let's Encrypt (external CA icon).

LAYOUT: Three vertical columns, top to bottom flow.

LEFT COLUMN — DB Credentials Flow:
  Column header: "Database Credentials" (blue header bar)
  
  [1] HashiCorp Terraform icon
      "terraform apply"
  ↓ solid arrow
  [2] AWS resource icon (generic)
      "random_password — 32 chars"
  ↓ solid arrow
  [3] RDS icon
      "aws_db_instance — MySQL 8.0"
      (password set at creation)
  ↓ solid arrow
  [4] Secrets Manager icon
      "/bookstore/db-credentials"
      JSON: { DB_USERNAME, DB_PASSWORD, DB_HOST }
  ↓ replication arrow (orange, right-pointing)
      "SM cross-region replica → us-west-2"
  ↓ solid arrow
  [5] IAM icon
      "IRSA — ESO ServiceAccount"
      "Trust: EKS OIDC → sts:AssumeRoleWithWebIdentity"
      "Policy: secretsmanager:GetSecretValue on /bookstore/*"
  ↓ solid arrow
  [6] Kubernetes icon
      "ExternalSecret CRD"
      "refreshInterval: 1h"
  ↓ solid arrow
  [7] Kubernetes icon
      "k8s Secret: db-secret"
      "bookstore namespace"
  ↓ solid arrow
  [8] Pod icon (Node.js)
      "backend pod env vars"
      "DB_HOST, DB_USERNAME, DB_PASSWORD"
      "via secretKeyRef"

CENTRE COLUMN — TLS Certificates Flow:
  Column header: "TLS Certificates" (orange header bar)
  
  [1] AWS Certificate Manager icon
      "ClusterIssuer: letsencrypt-prod"
      "ACME email: kandukurisaikrishna778@gmail.com"
  ↓
  [2] Kubernetes ingress icon
      "Ingress annotation:"
      "cert-manager.io/cluster-issuer: letsencrypt-prod"
  ↓
  [3] nginx icon
      "nginx-ingress serves ACME challenge"
      "GET /.well-known/acme-challenge/"
  ↓
  [4] External CA icon
      "Let's Encrypt CA"
      "validates domain ownership"
      "issues TLS certificate"
  ↓
  [5] Kubernetes icon
      "k8s TLS Secret"
      "bookstore namespace"
      "auto-renewed 30d before expiry"
  ↓
  [6] nginx icon
      "nginx-ingress"
      "terminates HTTPS :443"
      "backend sees HTTP"

RIGHT COLUMN — Grafana Admin Password Flow:
  Column header: "Grafana Admin Password" (green header bar)
  
  [1] Terraform icon
      "terraform apply"
  ↓
  [2] Resource icon
      "random_password — 24 chars, no specials"
  ↓
  [3] Secrets Manager icon
      "/bookstore/grafana-admin"
      "recovery_window: 7 days"
  ↓
  [4] Helm icon
      "kube-prometheus-stack helm release"
      "set_sensitive: grafana.adminPassword"
  ↓
  [5] Grafana icon
      "Grafana pod starts with password"
  ↓
  [6] Terminal icon
      "Retrieve:"
      "aws secretsmanager get-secret-value"
      "--secret-id /bookstore/grafana-admin"

BOTTOM — IRSA Trust Chain (spans all columns):
  Horizontal flow box:
  EKS OIDC Provider → IAM Role (sts:AssumeRoleWithWebIdentity)
  → ESO ServiceAccount → Secrets Manager API
  Label: "No long-lived credentials. Trust is pod-identity via OIDC."

STYLE RULES:
  - Three columns with coloured header bars (blue/orange/green)
  - White background
  - AWS official 2024 service icons for every box
  - Solid arrows for data flow, dashed for optional/async paths
  - Grey annotation text alongside arrows showing timing (e.g., "refreshed every 1h")
  - Font: Arial 10pt
```

---

## Diagram 4 — Canary Rollout & Observability Flow

**Tool:** draw.io or Lucidchart | **Format:** PNG | **Orientation:** Landscape

### Prompt

```
Create an AWS architecture diagram in official AWS style showing the Argo Rollouts 
canary deployment flow with Prometheus-gated analysis for the backend service.

ICONS: Argo Rollouts logo, ArgoCD logo, Prometheus icon, Grafana icon, 
Loki icon, nginx icon, AWS EKS icon, GitHub Actions icon.

LAYOUT: Left-to-right flow for the canary steps, with observability stack on right side.

TOP — Trigger Chain:
  GitHub Actions icon → ECR icon (image push: bookstore-backend:abc1234)
  → ArgoCD icon (detects kustomization.yaml change, 3 min poll)
  → EKS icon (new Rollout revision created)

CENTRE — Canary Traffic Split (main flow, left to right):
  Show as a horizontal PIPELINE with stages:

  ┌──────────────────────────────────────────────────────────────────────────┐
  │ Argo Rollouts Canary Pipeline                                            │
  │                                                                          │
  │ [STEP 1]         [STEP 2]          [STEP 3]       [STEP 4]  ...        │
  │ setWeight 10%    AnalysisRun ✓     pause 30s      setWeight 25%        │
  │ 90% stable       error-rate        waiting        75% stable            │
  │ 10% canary       < 5% threshold                   25% canary            │
  │                  failureLimit:2                                          │
  │ [STEP 5]         [STEP 6]          [STEP 7]       [STEP 8]             │
  │ pause 30s        setWeight 50%     AnalysisRun ✓  pause 60s           │
  │                  50/50 split       repeat check   → PROMOTE 100%       │
  └──────────────────────────────────────────────────────────────────────────┘

  Traffic split visualisation below each step:
  Show a bar divided [STABLE | CANARY] with percentages

  FAILURE PATH (red branch from any AnalysisRun box):
  AnalysisRun FAIL (2 consecutive) → Argo Rollouts ABORT
  → stable version back to 100% → Rollout status: Degraded
  → label: "kubectl argo rollouts abort backend -n bookstore"

  nginx canary-weight annotation note:
  "nginx-ingress canary-weight annotation controls actual traffic split"

RIGHT SIDE — Observability Stack:
  Prometheus icon
  "scrapes backend /metrics (prom-client) every 15s"
  "ServiceMonitor CRD auto-discovers backend service"
  ↓
  "Metrics: http_requests_total{method,route,status}"
  "         http_request_duration_seconds{method,route,status}"
  ↓ feeds (arrow)
  AnalysisTemplate icon
  "AnalysisRun query:"
  "sum(5xx rate [2m]) / sum(all rate [2m]) < 0.05"
  "or vector(0) — prevents div-by-zero on zero traffic"
  ↓ feeds (arrow)
  Grafana icon
  "Dashboards: request rate, p50/p95 latency, error rate, CPU/mem"
  ↓
  Loki icon
  "Promtail DaemonSet → pod logs → LogQL in Grafana"
  ↓
  Alertmanager icon
  "PrometheusRule: HighErrorRate — 5xx > 1% for 2min → alert"

STYLE RULES:
  - Canary pipeline box: light blue background, rounded corners
  - PASS steps: green (#4CAF50) border
  - FAIL path: red (#F44336) dashed arrows
  - PROMOTE step: solid green box with checkmark
  - Observability stack: right column, white boxes with AWS/tool icons
  - All arrows labelled with what triggers them
  - Font: Arial 10-12pt
  - Official AWS icons for EKS, ECR; official tool logos for Argo/Prometheus/Grafana
```

---

## Diagram 5 — CI/CD Pipeline (GitHub Actions)

**Tool:** draw.io or Eraser.io | **Format:** PNG | **Orientation:** Landscape

### Prompt

```
Create a CI/CD pipeline diagram in official AWS style using swim lanes for the 
Bookstore application GitHub Actions workflows.

ICONS: GitHub Actions icon, Docker icon, AWS ECR icon, AWS EKS icon (via ArgoCD),
Trivy icon, Semgrep icon, Gitleaks icon, Terraform icon, ArgoCD icon, Argo Rollouts icon.

LAYOUT: Horizontal swim lanes (left = trigger, right = output).

═══════════════════════════════════════════════════════════════════
WORKFLOW 1 — ci-cd.yml (Application)     Trigger: push/PR to main or improvements
═══════════════════════════════════════════════════════════════════

SWIM LANE 1: Security Scanning
  ┌──────────────────────────────────────────────┐
  │ [secret-scan]                                │
  │ Gitleaks icon — "full git history scan"      │
  │ ❌ FAIL → workflow stops immediately         │
  └──────────────────────────────────────────────┘
  (must pass before ANY other stage runs)

SWIM LANE 2: Test & SAST (parallel with lane 3, after lane 1)
  ┌──────────────────────────────────────────────┐
  │ [sast]                                       │
  │ vitest icon — "backend unit tests"           │
  │ npm audit — "high (backend) critical (FE)"  │
  │ Semgrep icon — "nodejs + owasp-top-ten"      │
  │ ❌ FAIL → blocks build-and-push             │
  └──────────────────────────────────────────────┘

SWIM LANE 3: Validate (parallel with lane 2)
  ┌──────────────────────────────────────────────┐
  │ [validate]                                   │
  │ ESLint icon — "frontend zero warnings"       │
  │ kubeconform icon — "k8s manifests v1.31.0"  │
  │ ❌ FAIL → blocks build-and-push             │
  └──────────────────────────────────────────────┘

SWIM LANE 4: Build & Push (only on push events, NOT PR)
  ┌──────────────────────────────────────────────┐
  │ [build-and-push]                             │
  │ AWS IAM icon — "OIDC login (no static keys)" │
  │ Docker icon — "buildx multi-stage build"     │
  │ GHA cache icon — "layer cache"               │
  │ Trivy icon — "CRITICAL+HIGH = HARD FAIL"     │
  │ SARIF → GitHub Security tab                  │
  │ ECR icon — "push :git-sha-8 (never :latest)" │
  │ ❌ Trivy FAIL → image never reaches ECR     │
  └──────────────────────────────────────────────┘

SWIM LANE 5: Deploy (only push to main + human approval)
  ┌──────────────────────────────────────────────┐
  │ [deploy] — requires GitHub "production" env  │
  │ ⏱ 30 min approval timeout                   │
  │ kustomize icon — "edit set image ECR_URL:SHA"│
  │ git commit + push kustomization.yaml         │
  │ (GITHUB_TOKEN, minimal scope, no re-trigger) │
  └──────────────────────────────────────────────┘
  → Arrow to: ArgoCD icon (detects change, 3 min)
  → Arrow to: Argo Rollouts icon (canary starts)

═══════════════════════════════════════════════════════════════════
WORKFLOW 2 — terraform.yml       Trigger: push/PR with *.tf changes
═══════════════════════════════════════════════════════════════════

SWIM LANE 1: IaC Security
  Trivy icon — "IaC scan all .tf files — CRITICAL+HIGH = FAIL"

SWIM LANE 2: Validate
  Terraform icon — "fmt -check | init | validate"

SWIM LANE 3: Plan
  Terraform icon — "terraform plan -out=tfplan"
  GitHub PR comment icon — "plan output posted to PR"

SWIM LANE 4: Apply (push to main only)
  Terraform icon — "terraform apply tfplan (pre-approved plan only)"

═══════════════════════════════════════════════════════════════════
WORKFLOW 3 — terraform-drift.yml     Trigger: daily cron 06:00 UTC
═══════════════════════════════════════════════════════════════════
  Terraform icon — "terraform plan -detailed-exitcode"
  exit 0 → ✅ no drift
  exit 2 → ❌ drift detected → GitHub alert notification
  exit 1 → ❌ plan error → investigate auth/state

BOTTOM ANNOTATION BOXES:
  ✅ "No AWS keys in GitHub Secrets — OIDC only"
  ✅ "Trivy blocks dirty images — never reach ECR"  
  ✅ "deploy stage gated by human approval on main"
  ✅ "terraform apply only runs pre-approved tfplan"

STYLE RULES:
  - Swim lane headers: dark grey background, white text
  - Security lanes: red (#FFEBEE) background
  - Test/validate lanes: blue (#E3F2FD) background
  - Build lane: orange (#FFF3E0) background
  - Deploy lane: green (#E8F5E9) background
  - FAIL paths: red dashed arrows pointing to ❌ BLOCKED box
  - Official tool icons: GitHub Actions, Docker, Trivy, Semgrep, Terraform, ArgoCD, Argo Rollouts
  - Official AWS icons: ECR, IAM
  - Font: Arial 10-12pt
```

---

## Diagram 6 — Network & Security Groups Deep Dive

**Tool:** draw.io with AWS19 icon pack | **Format:** PNG | **Orientation:** Portrait

### Prompt

```
Create an AWS VPC network diagram in official AWS style showing all subnets, 
security groups, and traffic flows for the Bookstore application.

ICONS: AWS official 2024 icons for all services. Use AWS VPC diagram conventions.

OUTER GROUPING:
  AWS Cloud boundary (light grey background)
  └── us-west-1 Region box (light blue dashed border)
      └── VPC 170.20.0.0/16 (solid green border, label top-left)

SUBNET LAYOUT (rows top to bottom inside VPC):

ROW 1 — Public Subnets (light green fill):
  ┌── AZ: us-west-1a (blue dashed border) ──────────────────┐
  │ Subnet: 170.20.1.0/24 (label top-left)                  │
  │ [Internet Gateway icon] [NAT Gateway icon]               │
  │ [NLB icon] "Network Load Balancer"                       │
  └──────────────────────────────────────────────────────────┘
  ┌── AZ: us-west-1c (blue dashed border) ──────────────────┐
  │ Subnet: 170.20.2.0/24                                    │
  │ [NLB icon] "NLB HA endpoint"                             │
  └──────────────────────────────────────────────────────────┘

ROW 2 — Private Subnets EKS (light blue fill):
  ┌── us-west-1a ─────────────┐  ┌── us-west-1c ─────────────┐
  │ 170.20.3.0/24             │  │ 170.20.4.0/24              │
  │ [EKS node icon]           │  │ [EKS node icon]            │
  └───────────────────────────┘  └───────────────────────────┘
  ┌── us-west-1a ─────────────┐  ┌── us-west-1c ─────────────┐
  │ 170.20.5.0/24 (overflow)  │  │ 170.20.6.0/24 (overflow)  │
  └───────────────────────────┘  └───────────────────────────┘

ROW 3 — Private Subnets RDS (light purple fill):
  ┌── us-west-1a ─────────────┐  ┌── us-west-1c ─────────────┐
  │ 170.20.7.0/24             │  │ 170.20.8.0/24              │
  │ [RDS icon] "MySQL PRIMARY" │  │ [RDS icon] "MySQL STANDBY" │
  └───────────────────────────┘  └───────────────────────────┘

SECURITY GROUPS (dashed coloured borders, overlaid on relevant resources):

SG-nginx (orange dashed border around NLB + ingress pods):
  Inbound:  :443 from 0.0.0.0/0 (HTTPS)
            :80 from 0.0.0.0/0 (HTTP → redirect)
  Outbound: :3000 to SG-eks, :8080 to SG-eks

SG-eks-nodes (blue dashed border around EKS node group):
  Inbound:  all from self (node-to-node)
            :443 from EKS control plane
            :8080, :3000 from SG-nginx
  Outbound: all (→ NAT for internet egress)

SG-rds (red dashed border around RDS subnets):
  Inbound:  :3306 from SG-eks ONLY
  Outbound: none

NUMBERED TRAFFIC FLOW ARROWS:
  ① Internet → IGW → NLB (:443, :80)
  ② NLB → nginx-ingress pod (SG-nginx allows)
  ③ nginx-ingress → frontend pod :8080
  ④ nginx-ingress → backend pod :3000
  ⑤ backend → NAT GW → Secrets Manager API (HTTPS)
  ⑥ backend → RDS :3306 (SG-rds allows from SG-eks)
  ⑦ EKS nodes → NAT GW → ECR (image pull, HTTPS)
  ⑧ EKS nodes → EKS API endpoint (HTTPS, public_access_cidrs restricted)
  ⑨ VPC → CloudWatch (VPC Flow Logs, ALL traffic ACCEPT+REJECT)

ROUTE TABLES (small table boxes):
  Public RT:  0.0.0.0/0 → IGW
  Private RT: 0.0.0.0/0 → NAT GW (us-west-1a)

NETWORK POLICY CALLOUT (purple box, bookstore namespace):
  Label: "Kubernetes NetworkPolicy — bookstore namespace"
  "default: deny all ingress + egress"
  Allowed:
  "→ ingress-nginx → frontend :8080"
  "→ ingress-nginx → backend :3000"
  "→ backend → RDS 170.20.7.0/24, 170.20.8.0/24 :3306"
  "→ all pods → kube-dns :53"
  "→ Prometheus → backend :3000/metrics"

STYLE RULES:
  - AWS official VPC diagram style
  - AZ boxes: blue dashed border (#1565C0)
  - Public subnets: light green (#E8F5E9)
  - Private EKS subnets: light blue (#E3F2FD)
  - Private RDS subnets: light purple (#F3E5F5)
  - Security group borders: dashed, colour-coded (orange/blue/red)
  - Traffic flow numbers in circles: ①②③... on arrows
  - AWS official 2024 service icons for all components
```

---

## Diagram 7 — Terraform Module Dependency Graph

**Tool:** `terraform graph | dot -Tsvg` (auto-generated) OR draw.io | **Format:** SVG/PNG

### Auto-generate (real graph):
```bash
# Install graphviz first
brew install graphviz

cd /path/to/repo
terraform graph | dot -Tsvg -o docs/terraform-dependency-graph.svg
terraform graph | dot -Tpng -o docs/terraform-dependency-graph.png
```

### Manual Prompt (if drawing in draw.io):

```
Create a Terraform module dependency DAG in official AWS style showing 
the infrastructure module structure and dependency relationships.

ICONS: Terraform (HashiCorp) logo for all boxes. AWS provider icon for 
provider alias nodes. AWS service icons for what each module creates.

NODE TYPES (different shapes):
  - Config files (providers.tf, variables.tf, locals.tf, data.tf): 
    grey rounded rectangle
  - Module boxes: blue rectangle with Terraform icon top-left
  - Root-level concern files (cloudfront.tf, dr.tf, cloudtrail.tf, guardduty.tf, iam.tf):
    orange rectangle with Terraform icon

PROVIDER ALIAS NODES (special boxes, top):
  [aws primary — us-west-1]    (solid green border)
  [aws.secondary — us-west-2]  (solid orange border)
  [aws.us_east_1 — us-east-1]  (solid red border, label: "CloudFront ACM hard requirement")
  [helm]                        (solid blue border)

ROOT CONFIG NODES (grey, top row):
  providers.tf → variables.tf → locals.tf → data.tf (aws_caller_identity)

MODULE DEPENDENCY GRAPH (blue boxes, middle):
  module.network          ← locals.tf (subnet CIDRs)
  module.security_groups  ← module.network (VPC ID)
  module.acm              ← module.network
  module.rds              ← module.network, module.security_groups
  module.ecr              ← providers.tf only
  module.eks              ← module.network, module.security_groups
  module.eks_addons       ← module.eks (explicit depends_on)
  module.route53          ← module.acm, module.network

ROOT CONCERN FILES (orange boxes, bottom):
  cloudtrail.tf   ← data.tf (aws_caller_identity for S3 bucket policy)
  guardduty.tf    ← providers.tf only
  cloudfront.tf   ← aws.us_east_1 provider, module.route53 (zone_id)
  dr.tf           ← aws.secondary provider, module.rds (instance ARN)
  iam.tf          ← data.tf (aws_caller_identity for OIDC trust)

OUTPUT DEPENDENCY ARROWS (dashed grey):
  module.network → [vpc_id, subnet_ids] → module.eks, module.rds, module.security_groups
  module.eks → [cluster_endpoint, oidc_url] → module.eks_addons
  module.rds → [rds_instance_arn] → dr.tf
  module.route53 → [zone_id] → cloudfront.tf
  cloudfront.tf → [cloudfront_domain] → module.route53 (try() safe ref, circular note)

ANNOTATION CALLOUTS:
  On dr.tf: "provider = aws.secondary (us-west-2 Oregon)"
  On cloudfront.tf: "provider = aws.us_east_1 (us-east-1 — CloudFront ACM hard requirement)"
  On cloudfront.tf ↔ route53 edge: "try() prevents plan-time error when enable_cloudfront=false"

STYLE RULES:
  - Top-to-bottom dependency flow (dependencies point downward)
  - Grey config nodes → Blue module nodes → Orange concern file nodes
  - Provider alias nodes: colour-coded by region (green=primary, orange=secondary, red=us-east-1)
  - Solid arrows: direct dependency
  - Dashed arrows: output reference
  - Font: Arial 10pt
  - White background, subtle drop shadows on boxes
```

---

## Diagram 8 — Full Architecture + Multi-Region DR (Combined)

**Tool:** draw.io with AWS19 icon pack | **Format:** PNG/SVG | **Orientation:** Landscape 16:9 (WIDE)

> This is the master diagram. Both regions coexist at all times. Primary serves 100% traffic. Secondary is warm standby with live replication. Failover = DNS flip.

### Prompt

```
Create a single comprehensive AWS architecture diagram in OFFICIAL AWS STYLE showing 
the complete Bookstore application across both regions exactly as it exists in 
production simultaneously.

ICONS: Official AWS Architecture Icons 2024 pack for ALL services.
       Kubernetes/CNCF logos for k8s-specific components.

GROUPING (AWS standard nesting):
  AWS Cloud boundary (light grey, spans full diagram)
  ├── Global strip (dark navy, top): Route53, CloudFront, ACM us-east-1 anchor
  ├── us-west-1 Region box (LEFT HALF, solid green border — ACTIVE)
  └── us-west-2 Region box (RIGHT HALF, dashed grey border — STANDBY)

GLOBAL STRIP (dark navy background, top, spans full width):

  [Left of strip]
  GitHub icon box:
  "GitHub repo — source of truth"
  GitHub Actions icon: "CI: secret-scan → sast → build → Trivy → ECR push"
  OIDC arrow → both regions' IAM icon (label: "keyless auth, no static AWS keys")

  [Centre of strip]
  Route53 icon (large)
  "b17facebook.xyz — Public Hosted Zone"
  Health Check icon below: "HTTPS :443, 30s interval, failure_threshold:3"
  Two arrows descending:
    LEFT:  solid arrow → us-west-1 NLB  label: "FAILOVER PRIMARY ✅ 100% traffic"
    RIGHT: dashed arrow → us-west-2 NLB label: "FAILOVER SECONDARY ⏸ dormant"

  [Right of strip]
  CloudFront icon: "CDN (optional, enable_cloudfront=true)"
  Small box: "us-east-1" + ACM icon
  "ACM cert — CloudFront hard requirement
   Independent of DR region"

══════════════════════════════════════════════════════════════════════════════════
LEFT HALF — us-west-1 N. California Region box  [solid green border]
Label: "🟢 PRIMARY — us-west-1 N. California — ACTIVE — 100% live traffic"
══════════════════════════════════════════════════════════════════════════════════

[VPC 170.20.0.0/16 — green border inside region]

Public Subnets (light green fill):
  AZ us-west-1a: Internet Gateway icon | NAT Gateway icon (label: "single NAT")
  AZ us-west-1c: (NLB spans both AZs)
  Network Load Balancer icon (NLB) — "LIVE TRAFFIC ⬇"

Private Subnets EKS (light blue fill, 4 subnets 170.20.3-6.0/24):
  EKS Cluster box (bookstore-eks, v1.31, EKS icon top-left)
  
  Inside EKS box — compact namespace rows (use small coloured rounded rect per namespace):
  
  Row 1 [bookstore namespace — blue]:
    nginx-ingress icon → frontend pod icon "React/Nginx :8080 (HPA 2-3)"
                       → backend pod icon "Node.js :3000 (Argo Rollout canary, HPA 1-5)"
                                          + /metrics endpoint marker
  
  Row 2 [observability — green]:
    Prometheus icon "scrapes /metrics" → Grafana icon "dashboards + Loki datasource"
    Alertmanager icon | Loki icon + Promtail icon "pod log collection"
  
  Row 3 [gitops — teal]:
    ArgoCD icon "polls GitHub 3min → applies k8s/overlays/prod/"
    Argo Rollouts icon "canary controller 10%→25%→50%→100%"
    AnalysisRun: Prometheus gates each step (< 5% error rate)
  
  Row 4 [platform — purple]:
    cert-manager icon "ClusterIssuer letsencrypt-prod"
    ESO icon "ExternalSecret refreshInterval:1h → SM → db-secret"
    EBS CSI icon "gp3 StorageClass (Prometheus TSDB)"

Private Subnets RDS (light purple fill, 170.20.7-8.0/24):
  AZ us-west-1a: RDS icon "MySQL 8.0 PRIMARY (db.t3.micro, 25GB gp2)"
  AZ us-west-1c: RDS icon "MySQL STANDBY (Multi-AZ auto-failover 60-120s)"
  Arrow: backend pod → :3306 → RDS (SG-rds: only from SG-eks)

AWS Managed Services column (right side of VPC, inside region):
  ECR icon "SOURCE" — bookstore-frontend, bookstore-backend (IMMUTABLE)
  Secrets Manager icon "SOURCE" — /bookstore/db-credentials, /bookstore/grafana-admin
  ACM icon — *.b17facebook.xyz (DNS validated)
  CloudTrail icon — multi-region, encrypted S3
  GuardDuty icon — EKS audit + S3 + malware
  CloudWatch icon — VPC Flow Logs (90d), RDS logs, EKS control plane logs
  S3+DynamoDB icon — Terraform state + lock

══════════════════════════════════════════════════════════════════════════════════
REPLICATION ARROWS (thick orange, spanning between regions, labelled "ALWAYS ACTIVE"):
══════════════════════════════════════════════════════════════════════════════════

Arrow 1: RDS PRIMARY → us-west-2 RDS Backup
  "aws_db_instance_automated_backups_replication
   7-day retention | continuous | provider: aws.secondary"

Arrow 2: ECR us-west-1 → ECR us-west-2
  "aws_ecr_replication_configuration
   prefix: bookstore-* | real-time | provider: aws.secondary"

Arrow 3: SM us-west-1 → SM us-west-2
  "Secrets Manager cross-region replication
   credentials always available in secondary"

══════════════════════════════════════════════════════════════════════════════════
RIGHT HALF — us-west-2 Oregon Region box  [dashed grey border]
Label: "🟡 SECONDARY — us-west-2 Oregon — WARM STANDBY"
══════════════════════════════════════════════════════════════════════════════════

SOLID boxes (exist RIGHT NOW, always running — full colour icons):
  ECR icon "REPLICA — real-time sync from us-west-1" (solid box)
  Secrets Manager icon "REPLICA — credentials ready" (solid box)
  AWS Backup icon "RDS backup store — 7-day retention" (solid box)

DASHED boxes (provisioned on DR event — greyscale icons, dashed borders):
  EKS icon (dashed box)
  "deploy on DR event
   same Terraform code
   same k8s manifests"

  NLB icon (dashed box)
  "provisioned during DR
   secondary_alb_dns → tfvars → terraform apply"

  RDS icon (dashed box)
  "restore from backup
   promote to standalone
   update DB_HOST in SM"

══════════════════════════════════════════════════════════════════════════════════
CENTRE CALLOUT BOX (between regions, mid-height):
══════════════════════════════════════════════════════════════════════════════════

Numbered sequence box (white, orange border, drop shadow):
Title: "Failover Sequence"
Subtitle: "Steps 1-2: automatic ⚡ | Steps 3-7: manual (~1 day)"

1. Health check fails 3× (90 seconds total)
2. Route53 auto-flips DNS → SECONDARY record active  ⚡ automatic
─────────────────────────────────────
3. Restore RDS from us-west-2 backup          ← manual
4. terraform apply — EKS + addons in us-west-2
5. Update /bookstore/db-credentials in us-west-2 SM (new DB_HOST)
6. set secondary_alb_dns in tfvars → terraform apply
7. ESO reads SM replica → backend pods get credentials

RPO: ~1h (SM replica sync interval)
RTO: ~1 day (EKS + RDS provisioning time)

══════════════════════════════════════════════════════════════════════════════════
RTO/RPO TABLE (bottom-right corner of diagram):
══════════════════════════════════════════════════════════════════════════════════
┌──────────────────────┬──────┬──────────┐
│ Failure Scenario     │ RPO  │ RTO      │
├──────────────────────┼──────┼──────────┤
│ Pod crash            │ 0    │ ~30s     │
│ Node failure         │ 0    │ ~2 min   │
│ RDS AZ failover      │ 0    │ 60-120s  │
│ Region failure       │ ~1h  │ ~1 day   │
└──────────────────────┴──────┴──────────┘

STYLE RULES:
  - Landscape 16:9, large canvas (recommend 4000×2250px minimum)
  - ALL AWS official 2024 service icons (download from aws.amazon.com/architecture/icons)
  - AWS Cloud outer border: light grey (#F5F5F5), bold dashed
  - Global strip: dark navy (#0D1117) background, white text
  - Primary region box: solid green (#2E7D32) border, 3px
  - Secondary region box: dashed grey (#9E9E9E) border, 2px
  - Active/warm standby components: full colour icons, solid box borders
  - On-demand components: 40% opacity greyscale icons, dashed box borders
  - Replication arrows: #FF9900 orange, 3px, with "ALWAYS ACTIVE" badge
  - DNS arrows from Route53: 2px — solid to primary, dashed to secondary
  - Namespace boxes inside EKS: small rounded rectangles, colour per function
  - Font: Amazon Ember or Arial, 10-12pt for labels, 14pt for region titles
  - White background inside region boxes
  - Subtle drop shadows on all major grouping boxes
```

---

## Quick Reference

| Diagram | Best Tool | Canvas Size | Format |
|---|---|---|---|
| 1 — Full Architecture | draw.io + AWS19 icons | 2400×3200 portrait | PNG/SVG |
| 2 — Multi-Region DR | draw.io + AWS19 icons | 3200×2000 landscape | PNG/SVG |
| 3 — Secrets Flow | Lucidchart or draw.io | 2400×3000 portrait | PNG |
| 4 — Canary Rollout | draw.io or Eraser.io | 3000×2000 landscape | PNG |
| 5 — CI/CD Pipeline | draw.io (swim lanes) | 3200×2400 landscape | PNG |
| 6 — Network & SGs | draw.io + AWS19 icons | 2400×3200 portrait | PNG/SVG |
| 7 — Terraform DAG | `terraform graph \| dot` | auto | SVG |
| 8 — Full + DR Combined | draw.io + AWS19 icons | 4000×2250 landscape | PNG/SVG |

### Download AWS Architecture Icons
```
https://aws.amazon.com/architecture/icons/
→ "AWS Architecture Icons" zip
→ Import into draw.io: Extras → Edit Diagram, or drag .xml into canvas
→ In draw.io search bar: type service name (e.g. "EKS", "RDS", "Route53")
```

### Import AWS Shape Library in draw.io
```
draw.io → Extras → Edit Diagram
OR
draw.io → File → Open from URL → paste AWS icon pack URL
OR (easiest):
draw.io → left sidebar → "Search shapes" → type AWS service name
```
