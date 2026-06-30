# Terraform Reference

Infrastructure-as-Code for the bookstore 3-tier app on AWS. Manages VPC, EKS, RDS, ECR, Route53, ACM, CloudFront, CloudTrail, GuardDuty, and all EKS add-ons via Helm.

---

## Quick Start

```bash
# 1. Bootstrap remote state (once per AWS account)
./scripts/bootstrap-tf-state.sh us-west-1

# 2. Fill backend config in versions.tf (printed by script above)
# 3. Init with remote state
terraform init -migrate-state

# 4. First apply (infrastructure only — leave primary_alb_dns empty)
terraform plan -out=tfplan
terraform apply tfplan

# 5. After EKS + ArgoCD deploy nginx-ingress, get NLB DNS
kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# 6. Add NLB DNS to terraform.tfvars, re-apply for Route53 records
terraform apply
```

---

## Providers

Three provider aliases — all defined in `providers.tf`:

| Alias | Region | Purpose |
|---|---|---|
| (default) | `us-west-1` | All primary region resources |
| `aws.secondary` | `us-west-2` (var) | DR: RDS backup replication, ECR replication |
| `aws.us_east_1` | `us-east-1` (hardcoded) | CloudFront ACM cert — AWS hard requirement |

`aws.us_east_1` is intentionally hardcoded to `us-east-1`. CloudFront only accepts ACM certs from `us-east-1` globally — this is an AWS platform constraint, not a DR region choice. Changing `secondary_region` to any value never breaks CloudFront.

```hcl
provider "aws" {
  region = var.aws_region   # us-west-1
}
provider "aws" {
  alias  = "secondary"
  region = var.secondary_region   # us-west-2 Oregon (DR)
}
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"    # CloudFront ACM only — never changes
}
```

---

## Variables Reference

| Variable | Type | Default | Description |
|---|---|---|---|
| `aws_region` | string | `us-west-1` | Primary region for all resources |
| `environment` | string | `prod` | Environment tag on all resources |
| `domain` | string | — | Primary domain (`b17facebook.xyz`) — required |
| `github_repo` | string | — | `owner/repo` — scopes OIDC CI role trust policy |
| `secondary_region` | string | `us-west-2` | DR failover region for ECR + RDS replication |
| `primary_alb_dns` | string | `""` | Nginx NLB DNS (us-west-1) — leave empty on first apply |
| `secondary_alb_dns` | string | `""` | Nginx NLB DNS (DR region) — fill after DR EKS deployed |
| `enable_cloudfront` | bool | `false` | Add CloudFront in front of frontend |

`terraform.tfvars` already contains defaults for `domain` and `github_repo`. Fill those in before first apply.

---

## Module Structure

```
.
├── providers.tf           # 3 provider aliases (see above)
├── versions.tf            # required_providers + S3 backend config
├── variables.tf           # all input variables
├── locals.tf              # VPC CIDR + all subnet CIDR/AZ pairs (shared across modules)
├── data.tf                # aws_caller_identity — consumed by IAM + CloudTrail
├── main.tf                # module calls only
├── outputs.tf             # VPC ID, ECR URLs, EKS endpoint, Route53 NSs, etc.
├── iam.tf                 # GitHub OIDC role + ECR push policy
│
# Root-level concern files (NOT in modules — see rationale below)
├── cloudfront.tf          # ACM cert (us-east-1) + CloudFront distribution
├── dr.tf                  # RDS automated-backup cross-region replication
├── cloudtrail.tf          # S3 bucket + bucket policy + CloudTrail trail
├── guardduty.tf           # GuardDuty detector
│
└── modules/
    ├── network/           # VPC, subnets, IGW, NAT GW, route tables, VPC flow logs
    ├── security/          # Security groups (EKS nodes, RDS, Nginx NLB)
    ├── acm/               # ACM cert for us-west-1 (EKS ingress TLS via cert-manager)
    ├── rds/               # RDS MySQL 8.0, Secrets Manager secret
    ├── ecr/               # ECR repos, lifecycle policies, cross-region replication
    ├── eks/               # EKS cluster, OIDC provider, managed node group, IAM roles
    └── eks-addons/        # All Helm releases + Grafana SM secret
```

---

## Root vs Module: Design Rationale

Three reasons files live at root instead of `modules/`:

### 1. Provider alias constraint (`cloudfront.tf`, `dr.tf`)

Terraform does not transparently pass provider aliases into child modules. Moving these would require:
- `providers = { aws.us_east_1 = aws.us_east_1 }` block in every module call
- Explicit alias declaration in child module `required_providers`

For 8–84 line files this is pure boilerplate with zero benefit. HashiCorp guidance: keep alias-targeted resources at root when they don't justify a dedicated module.

### 2. Account-level resources (`cloudtrail.tf`, `guardduty.tf`)

- **CloudTrail** — audits the entire AWS account. Not owned by network, EKS, or RDS.
- **GuardDuty** — one detector per account. No module owns it.

Account-scope security controls live at root. Standard Terraform community pattern.

### 3. Shared data sources and locals (`data.tf`, `locals.tf`)

- `data "aws_caller_identity"` consumed by `iam.tf` AND `cloudtrail.tf`. Data sources don't cross module boundaries.
- `locals.tf` VPC subnet CIDRs passed to `module.network`, `module.security`, `module.eks` — must be at root.

### Rule of thumb

| Put at root | Put in module |
|---|---|
| Uses `provider = aws.secondary` or `aws.us_east_1` | Logically cohesive resource group (VPC, EKS, RDS) |
| Account-wide service (CloudTrail, GuardDuty) | Can be reused or independently versioned |
| Data source consumed by 2+ modules | Single concern, clear ownership |
| Locals shared across 2+ module calls | — |

---

## Module Details

### `modules/network/`
- VPC `170.20.0.0/16`
- 2 public subnets (NAT GW, NLB), 4 private subnets (EKS nodes), 2 RDS subnets
- Internet Gateway, NAT Gateway (single, us-west-1a — cost optimised)
- Route tables: public → IGW, private → NAT
- VPC Flow Logs → CloudWatch `/aws/vpc/flowlogs/bookstore` (90-day retention)

### `modules/security/`
- Security group: EKS nodes (ingress from NLB + inter-node, egress all)
- Security group: RDS (ingress port 3306 from EKS nodes only)
- Security group: Nginx NLB (ingress 80/443 from 0.0.0.0/0)

### `modules/acm/`
- ACM cert for primary domain + wildcard `*.domain` in `us-west-1`
- DNS validation (Route53 CNAME auto-created)

### `modules/rds/`
- MySQL 8.0, `db.t3.micro`, Multi-AZ, 25GB gp2 (autoscales to 100GB)
- `random_password` (32 chars) — never hardcoded
- `aws_secretsmanager_secret` at `/bookstore/db-credentials` with `DB_USERNAME`, `DB_PASSWORD`, `DB_HOST`
- SM replica in `us-west-2` (DR)
- Performance Insights (7d), Enhanced Monitoring (60s), CloudWatch Logs (error/general/slowquery)
- `deletion_protection = true`, final snapshot on destroy

### `modules/ecr/`
- Repos: `bookstore-backend`, `bookstore-frontend`
- IMMUTABLE tags (no overwrite)
- Lifecycle: keep last 10 images
- Cross-region replication: all `bookstore-*` repos → `us-west-2` Oregon

### `modules/eks/`
- EKS 1.31 cluster (`bookstore-eks`)
- OIDC provider (required for IRSA)
- Managed node group: `t3.medium`, min 1 / max 2, AL2_x86_64
- Control plane logs: api, audit, authenticator, controllerManager, scheduler
- IAM: cluster role + node group role (least-privilege managed policies)

### `modules/eks-addons/`
All installed via `helm_release`. Deployed after EKS cluster is ready.

| Add-on | Namespace | Helm chart |
|---|---|---|
| aws-ebs-csi-driver | kube-system | EKS managed addon |
| cert-manager | cert-manager | `cert-manager/cert-manager` v1.16.2 |
| external-secrets | external-secrets | `external-secrets/external-secrets` v0.10.7 |
| ingress-nginx | ingress-nginx | `ingress-nginx/ingress-nginx` |
| kube-prometheus-stack | monitoring | `prometheus-community/kube-prometheus-stack` |
| loki-stack | monitoring | `grafana/loki-stack` |
| argo-rollouts | argo-rollouts | `argo/argo-rollouts` v1.7.2 |
| argo-cd | argocd | `argo/argo-cd` |

`grafana-secret.tf` in this module creates `random_password` (24 chars, no specials) → `/bookstore/grafana-admin` SM secret.

### `modules/route53/`
- Public hosted zone for primary domain
- Private zone `bookstore.internal` → RDS CNAME
- `aws_route53_health_check.primary`: HTTPS :443, 30s interval, `failure_threshold: 3`
- `FAILOVER PRIMARY` record → primary NLB DNS (`var.primary_alb_dns`)
- `FAILOVER SECONDARY` record → DR NLB DNS (`var.secondary_alb_dns`, when non-empty)

---

## State Backend

```hcl
backend "s3" {
  bucket         = "bookstore-terraform-state-<ACCOUNT_ID>"
  key            = "prod/terraform.tfstate"
  region         = "us-west-1"
  dynamodb_table = "terraform-state-lock"
  encrypt        = true
}
```

Run `./scripts/bootstrap-tf-state.sh us-west-1` once to create bucket + DynamoDB table. Script prints the exact block to paste into `versions.tf`. Then `terraform init -migrate-state`.

---

## Key Outputs

```bash
terraform output rds_endpoint              # DB_HOST for secrets manager
terraform output eks_cluster_name          # for kubeconfig
terraform output route53_public_name_servers  # paste into registrar NS records
terraform output rds_secret_arn            # ARN for ESO ClusterSecretStore
terraform output ecr_backend_url           # full ECR URL for backend image
terraform output ecr_frontend_url          # full ECR URL for frontend image
```

---

## CI/CD Integration

`terraform.yml` workflow runs on `.tf` file changes to `main`:
1. Trivy IaC scan (CRITICAL+HIGH = fail)
2. `terraform fmt -check`
3. `terraform init`, `terraform validate`
4. `terraform plan` → posts output as PR comment
5. `terraform apply` — only on push to `main` (not PR)

Drift detection runs daily at 06:00 UTC via `terraform-drift.yml`. Uses `-detailed-exitcode`: exit 2 = drift found → job fails → GitHub alert.

---

## Disaster Recovery

`dr.tf` provisions `aws_db_instance_automated_backups_replication` → replicates RDS automated backups to `var.secondary_region` (us-west-2).

`cloudfront.tf` provisions ACM cert in `us-east-1` (hardcoded via `aws.us_east_1` alias) and CloudFront distribution. Enable with `enable_cloudfront = true` + `primary_alb_dns` set.

Failover flow when primary fails:
1. Route53 health check fails 3× → auto-switches to `FAILOVER SECONDARY` record
2. Restore RDS from backup in us-west-2
3. Deploy EKS in us-west-2 (same Terraform, same manifests)
4. Update `/bookstore/db-credentials` in us-west-2 SM replica with new `DB_HOST`
5. Set `secondary_alb_dns` in `terraform.tfvars` → `terraform apply`
