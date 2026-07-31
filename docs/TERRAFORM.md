# Terraform

Everything under `modules/` plus the root `.tf` files. This is the actual current state of the code on `observability`, not a design doc.

## Layout

```
main.tf              — module wiring, call order, root-level resources (EIP, catalog DB creds)
variables.tf          — root input variables
outputs.tf             — root outputs
locals.tf              — VPC CIDR + subnet layout (single source of truth)
data.tf                 — data "aws_caller_identity" "current"
providers.tf              — aws (default + us-east-1 + secondary aliases), helm
versions.tf                — required_version, required_providers, S3 backend block
iam.tf                       — GitHub Actions OIDC role
cloudtrail.tf                 — multi-region CloudTrail
guardduty.tf                   — GuardDuty detector
cloudfront.tf                    — optional CDN in front of the frontend
dr.tf                              — cross-region RDS backup replication
terraform.tfvars                    — region/domain/github_repo values (not secret)
modules/
  network/       — VPC, subnets, IGW, NAT, flow logs
  security/       — security groups
  acm/              — ACM certificate
  rds/               — MySQL instance + admin secret
  route53/             — private + public DNS zones
  ecr/                   — ECR repos
  eks/                     — cluster + node group + OIDC provider
  eks-addons/                — Helm-installed cluster add-ons
  monitoring-ec2/               — standalone monitoring stack
```

## Backend state

```hcl
# versions.tf
backend "s3" {
  bucket         = ""   # deliberately empty in git
  key            = "prod/terraform.tfstate"
  region         = "us-west-1"
  dynamodb_table = ""   # deliberately empty in git
  encrypt        = true
}
```

The bucket/table names are account-specific, so they're never committed. Run `scripts/init-backend.sh us-west-1` once per AWS account — it creates the S3 bucket + DynamoDB lock table, patches `versions.tf` in place with the real names, and runs `terraform init`. (`scripts/bootstrap-tf-state.sh` is an older version of the same idea that prints the block for you to paste manually instead of patching the file — redundant now that `init-backend.sh` exists, kept for reference.)

**If you skip this step**, Terraform silently falls back to local state (`.terraform/terraform.tfstate`), which is what makes `terraform plan` show "100 to add" even when a cluster is already running — the plan has no idea anything exists. Always check `terraform state list` before trusting a plan's resource count.

## Module: `network`

VPC `170.20.0.0/16`, 2 public + 6 private subnets (see [`ARCHITECTURE.md`](ARCHITECTURE.md#subnet-layout) for exact layout), one Internet Gateway, **one** NAT Gateway (cost tradeoff — no per-AZ redundancy), VPC Flow Logs to CloudWatch (90-day retention).

Notable: a `null_resource` with a `destroy`-time `local-exec` provisioner force-deletes the flow-log CloudWatch log group with a 15s sleep first. Why: AWS's VPC Flow Logs service self-heals its log group — if Terraform deletes the group while flow logs are still actively delivering, the service just recreates it, and then the VPC delete fails because a "foreign" log group exists that Terraform doesn't own. The `depends_on = [aws_flow_log.vpc]` ordering plus the sleep exists specifically to let in-flight delivery stop first. This was reverse-engineered from CloudTrail (`lookup-events` by `EventName`, not `ResourceName` — the latter returns nothing for this event type).

## Module: `security`

Two security groups: `alb_frontend` (80/443 from `0.0.0.0/0`, all egress) and `rds` (3306 from the VPC CIDR only). RDS has **no egress rule** — it never initiates outbound connections, so one isn't needed (a `rds_egress` rule allowing `0.0.0.0/0` egress used to exist here and was removed as unnecessary blast radius).

## Module: `acm`

One ACM certificate, DNS validation, with a wildcard SAN (`*.<domain>`). Has an `ignore_changes = [domain_validation_options]` lifecycle block that produces a harmless but permanent Terraform warning — `domain_validation_options` is provider-computed, so `ignore_changes` on it is a no-op. Low-priority cleanup, not a bug.

## Module: `rds`

MySQL 8.0, `db.t3.micro`, Multi-AZ, 25GB storage (autoscaling to 100GB), 7-day backup retention, encrypted at rest (AWS-managed key by default). Admin credentials generated with `random_password` and stored in Secrets Manager at `/bookstore/db-credentials` (`recovery_window_in_days = 0` — force-delete on destroy, no 7/30-day soft-delete window, so repeated destroy/apply cycles during development don't collide on a pending-deletion secret name).

`performance_insights_enabled = false` — not supported on `db.t3.micro`, would hard-fail `terraform apply` if enabled. Enhanced Monitoring (`monitoring_interval = 60`) is separate and does work on this instance class.

`deletion_protection = false`, `skip_final_snapshot = true` — deliberately, to make `terraform destroy` actually complete without manual intervention. This is a real tradeoff for a project that gets destroyed/recreated often; a persistent production deployment would flip both.

Optional cross-region automated-backup replication exists (`dr.tf`) but requires an explicit KMS CMK in the secondary region — AWS-managed keys can't replicate cross-region. Off by default (`dr_kms_key_id = ""`).

## Module: `route53`

Private hosted zone for RDS internal DNS (a CNAME pointing at the RDS endpoint). Public hosted zone with **active-passive failover routing**: a health check on the primary domain (HTTPS, `/`, 3 failures @ 30s interval) backs a `PRIMARY` failover record pointing at the primary-region ALB/NLB DNS, and a `SECONDARY` record for the secondary region (only created if `secondary_alb_dns` is set — which it isn't yet, since there's no secondary EKS cluster). If CloudFront is enabled, the primary record points at the CloudFront distribution domain instead of the ALB directly.

## Module: `ecr`

Originally hardcoded to exactly two repos (`bookstore-frontend`, `bookstore-backend`). Generalized on this branch with an `extra_repos` list variable:

```hcl
locals {
  repos = concat(
    ["${var.prefix}-frontend", "${var.prefix}-backend"],
    [for r in var.extra_repos : "${var.prefix}-${r}"]
  )
}
```

Called from root `main.tf` with `extra_repos = ["catalog-service"]`. A generic `repo_urls` map output (`{short_name => repository_url}`) was added alongside the existing named `frontend_repo_url`/`backend_repo_url` outputs — the named outputs stay for backward compatibility, `repo_urls` is what future services use. All repos are `IMMUTABLE` tag mutability (first push per tag must use a unique tag — CI already does this via git SHA), `scan_on_push = true`, AES256 encryption, 10-image retention lifecycle policy. Cross-region replication uses a prefix filter (`PREFIX_MATCH` on `var.prefix`), so any new repo under the `bookstore-` prefix is automatically covered without touching the replication config.

## Module: `eks`

EKS 1.31, managed node group on `t3.medium` (min 1 / max 2 / desired 2 — desired was bumped from 1 to 2 specifically because a single `t3.medium` node hits its ENI pod-IP ceiling (~17 pods) before the full ArgoCD stack even fits, see TROUBLESHOOTING TF-014). `access_config.authentication_mode = "API_AND_CONFIG_MAP"` with explicit `aws_eks_access_entry`/`aws_eks_access_policy_association` resources granting cluster-admin to every ARN in `var.admin_principal_arns` (always includes whoever is running `terraform apply`, via `data.aws_caller_identity.current.arn`). This exists because EKS's `bootstrap_cluster_creator_admin_permissions` only fires once, at the literal `CreateCluster` API call — it doesn't retroactively grant access to a different person running `apply` later, and doesn't survive certain module refactors. The access-entry resources are the persistent, re-appliable equivalent.

An `aws_iam_openid_connect_provider` is created from the cluster's OIDC issuer — this is what makes IRSA (IAM Roles for Service Accounts) possible for everything downstream (External Secrets Operator, EBS CSI driver).

The node launch template's `user_data` runs `node-user-data.sh.tftpl` — a `templatefile()` render that installs `node-exporter` and `Fluent Bit` as systemd services (not DaemonSets — see [`ARCHITECTURE.md`](ARCHITECTURE.md#why-monitoring-runs-on-ec2-not-in-the-cluster) for why monitoring isn't in-cluster). **This file must be pure ASCII** — AL2's cloud-init uses Python 2.7's ASCII-only MIME parser, and a single non-ASCII character anywhere (even in a comment) silently kills the entire user-data script before the EKS bootstrap command ever runs, leaving nodes that boot but never join the cluster. This has broken the build three times; see TROUBLESHOOTING TF-009. `metadata_options` enforces IMDSv2 (`http_tokens = "required"`) with `http_put_response_hop_limit = 2` (containers on the node need one extra hop to reach IMDS versus the host itself).

## Module: `eks-addons`

Helm-installed cluster add-ons, all via `helm_release`:

| Chart | Namespace | Notes |
|---|---|---|
| cert-manager | `cert-manager` | CRDs installed, single replica |
| external-secrets | `external-secrets` | ServiceAccount explicitly named `external-secrets-sa` with an IRSA role annotation — see below |
| ingress-nginx | `ingress-nginx` | `LoadBalancer` service type → provisions a real AWS NLB as a side effect, invisible to Terraform (see destroy notes) |
| argocd | `argocd` | No `depends_on` (see below) |
| argo-rollouts | `argo-rollouts` | No `depends_on` (see below) |
| aws-ebs-csi-driver | (EKS addon, not Helm) | IAM policy attached to the node role first |

**All 5 Helm charts + the EBS CSI addon now install concurrently, on this branch.** They used to be partially serialized (`argocd` waited on `ingress-nginx`; `argo-rollouts` waited on `argocd`) as a resource-contention workaround from when the node group was a single `t3.medium` (see TF-001/TF-006). Once `node_desired_size` went to 2 (TF-014), that workaround was never revisited — the two remaining `depends_on` lines were pure leftover, not a real functional requirement (ArgoCD isn't exposed via ingress or TLS in this config, and Argo Rollouts is an unrelated project from ArgoCD). Removed to cut apply time; the critical path through this module is now roughly `max(all 5 timeouts)` (ArgoCD's 900s) instead of the old serialized sum. **If a real apply on this node size starts hitting TF-001-shaped timeout failures again, the fix is re-adding `depends_on = [helm_release.ingress_nginx]` on `argocd` and `depends_on = [helm_release.argocd]` on `argo_rollouts`** in `modules/eks-addons/gitops.tf`, not scaling the node group further — this hasn't been verified against a real apply yet (see [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) OBS-006).

**The External Secrets IRSA fix** (this branch, commit `b48c3d3`): the Helm release used to install ESO with zero IRSA wiring — no IAM role, no ServiceAccount annotation — even though `k8s/base/secrets/external-secret.yaml`'s `ClusterSecretStore` already expected a ServiceAccount named exactly `external-secrets-sa`. Nothing could ever actually authenticate to Secrets Manager. Fixed with a trust-policy IAM role scoped to `/bookstore/*` in Secrets Manager, plus explicit `serviceAccount.name`/`serviceAccount.annotations` Helm `set` values:

```hcl
condition {
  test     = "StringEquals"
  variable = "${replace(var.oidc_provider_url, "https://", "")}:sub"
  values   = ["system:serviceaccount:external-secrets:external-secrets-sa"]
}
```

The `replace(..., "https://", "")` matters — the OIDC provider URL always arrives with the scheme attached, but STS populates the federated-JWT trust-condition keys *without* it. Leaving the scheme in silently breaks the `StringEquals` match (this was caught in code review before it ever touched real infra — see TROUBLESHOOTING.md).

Helm install ordering used to be a real problem (all 6+ charts installing in parallel on one small node — see TF-001/TF-006 in TROUBLESHOOTING.md). Current state: all 5 charts install fully concurrently — see the parallel-execution note above.

## Module: `monitoring-ec2`

One `t3.small` EC2 instance with an Elastic IP, running Prometheus + Grafana + Loki + Alertmanager + kube-state-metrics via Docker Compose (user-data script templates the entire `docker-compose.yml` and configs at boot — see [`KUBERNETES.md`](KUBERNETES.md) for what it actually scrapes). It reads `module.eks_addons.grafana_admin_secret_arn`, but the call site in root `main.tf` **no longer has a blanket `depends_on = [module.eks_addons]`** — that used to force this EC2 to wait for every Helm chart in `eks-addons` to finish (up to 900s for ArgoCD alone) when it only actually needs the fast `grafana_admin` secret, which Terraform already tracks as a dependency via the direct output reference. It now starts as soon as `module.eks` is ready, in parallel with all of `eks-addons`.

The EIP is created as a **root-level resource** (`aws_eip.monitoring` in `main.tf`), not inside the module, specifically to avoid a circular dependency: its `public_ip` is needed by `module.eks` (for the Fluent Bit config in node user-data) *and* by `module.monitoring_ec2` itself, and creating it as a plain root resource means both can reference the same known-at-plan-time value without depending on each other.

## Root: `iam.tf` — GitHub OIDC role

Lets GitHub Actions assume an AWS role via OIDC token exchange — no static `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` anywhere. Trust policy restricts `sts:AssumeRoleWithWebIdentity` to `token.actions.githubusercontent.com:sub` matching `repo:<org>/<repo>:ref:refs/heads/main` or `refs/heads/improvements` specifically — a branch not in that list (like `observability`) cannot assume this role, which is why CI's `build-and-push` job needed its own branch check added, not just a workflow trigger change (see [`CICD.md`](CICD.md)). One-time manual prerequisite outside Terraform: the OIDC identity provider itself (`aws iam create-open-id-connect-provider ...`) must exist in the account before this role can reference it.

## Root: `cloudtrail.tf`, `guardduty.tf`

Multi-region CloudTrail writing to a dedicated, encrypted, versioned, public-access-blocked S3 bucket (`force_destroy = true` — needed because the bucket is versioned, and an empty-looking-but-actually-versioned bucket otherwise blocks delete). GuardDuty detector with S3, Kubernetes audit log, and EBS malware-scan data sources all enabled.

## Root: `cloudfront.tf`

Optional (`enable_cloudfront`, default `false`). If enabled, needs `primary_alb_dns` set. The ACM cert for CloudFront **must** be in `us-east-1` regardless of the deployment region — a hard AWS requirement — so it uses a distinct `aws.us_east_1` provider alias, deliberately separate from the `aws.secondary` alias used for DR, so the DR region can be changed independently of where the CDN cert lives.

## Root: `dr.tf`

Just the cross-region RDS automated-backup replication resource, gated on `var.dr_kms_key_id != ""`. See [Module: rds](#module-rds) above.

## Root: catalog-service additions (this branch)

Alongside the ECR `extra_repos` change, root `main.tf` also provisions the catalog-service's own DB credentials — same pattern as the RDS module's admin secret, just for a scoped, service-specific MySQL user:

```hcl
resource "random_password" "catalog_db_password" { ... }
resource "aws_secretsmanager_secret" "catalog_db_credentials" {
  name = "/bookstore/catalog-db-credentials"
}
resource "aws_secretsmanager_secret_version" "catalog_db_credentials" {
  secret_string = jsonencode({
    DB_USERNAME = "catalog_user"
    DB_PASSWORD = random_password.catalog_db_password.result
    DB_HOST     = module.rds.rds_endpoint
    DB_NAME     = "catalog_db"
  })
}
```

The actual MySQL schema + user creation is **not** Terraform's job — RDS doesn't expose a Terraform-native way to run arbitrary SQL. That happens via a one-off Kubernetes Job (`k8s/services/catalog-service/bootstrap/schema-init-job.yaml`), run once by hand against the admin credentials after `apply`. See [`KUBERNETES.md`](KUBERNETES.md) and [`DEPLOYMENT.md`](DEPLOYMENT.md).

## Common commands

```bash
terraform init                          # after scripts/init-backend.sh has run once
terraform validate                      # safe, no cloud calls
terraform plan -out=tfplan               # review before applying anything
terraform apply tfplan
terraform destroy                        # tears down everything — see DEPLOYMENT.md first
```

The `Makefile` wraps the common sequence:

```bash
make plan     # init + plan
make apply    # init + import (known pre-existing secrets) + apply -auto-approve
make destroy  # destroy -auto-approve
```

`make import` exists because repeated destroy/apply cycles during development sometimes leave Secrets Manager entries that Terraform's state doesn't know about (state gets reset, but AWS resources with `recovery_window_in_days` sometimes linger) — it's a `terraform import ... || echo already imported` no-op-safe step, not something you need to think about on a genuinely fresh account.

## Known gaps

- Terraform state must be bootstrapped manually per-account (`scripts/init-backend.sh`) — there's no automation that does this as part of `terraform apply` itself, and if you skip it, `plan` silently uses local state and will look like it wants to create everything from scratch even when a cluster already exists live. **Always run `terraform state list` before trusting a plan.**
- `eks_bootstrap.py` at the repo root is a legacy script from before `modules/eks-addons` existed — back when cert-manager/ESO/ingress-nginx/ArgoCD were installed by hand via a Python script instead of Terraform `helm_release` resources. It's very likely dead now; nothing in the current apply flow calls it. Worth deleting once confirmed unused (see [`FUTURE_IMPROVEMENTS.md`](FUTURE_IMPROVEMENTS.md)).
- `catalog_db_credentials` and the schema-init Job assume a single shared MySQL instance with per-service logical schemas — this is intentionally not full RDS-per-service isolation (see the design spec's Non-goals).
