# Terraform

Everything under `modules/` plus the root `.tf` files. This is the actual current state of the code on `observability`, not a design doc.

## Layout

```
main.tf              — module wiring, call order, root-level resources (EIP, catalog DB creds)
variables.tf          — root input variables
outputs.tf             — root outputs
locals.tf              — VPC CIDR + subnet layout (single source of truth)
data.tf                 — data "aws_caller_identity" "current"
providers.tf              — aws (default + us-east-1 + secondary aliases), helm, kubernetes, kubectl
versions.tf                — required_version, required_providers, S3 backend block
iam.tf                       — GitHub Actions OIDC role
cloudtrail.tf                 — multi-region CloudTrail
guardduty.tf                   — GuardDuty detector
cloudfront.tf                    — optional CDN in front of the frontend
ingress-cert.tf                    — regional ACM cert (DNS-validated) for the ALB's TLS
dr.tf                                — cross-region RDS backup replication
argocd.tf                              — Terraform-managed ArgoCD Application/ApplicationSet + ALB hostname auto-discovery
terraform.tfvars                        — region/domain/github_repo values (not secret)
modules/
  network/       — VPC, subnets, IGW, NAT, flow logs
  security/       — security groups
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
  bucket                = ""   # deliberately empty in git
  key                   = "terraform.tfstate"
  workspace_key_prefix  = "environments"
  region                = ""   # deliberately empty in git
  use_lockfile          = true # native S3 state locking, no DynamoDB table
  encrypt               = true
}
```

The bucket name is account-specific, so it's never committed — and neither is `region`, as of this branch (it used to be hardcoded `"us-west-1"` directly in the committed file, completely disconnected from `config.env`'s `AWS_REGION` or anything else region-related in this project). Run `scripts/init-backend.sh` once per AWS account — it creates the S3 bucket, patches `versions.tf` in place with the real bucket name *and* region, and runs `terraform init`. Region resolution is layered: an explicit CLI arg (`./scripts/init-backend.sh us-west-2`) takes priority, then `AWS_REGION` from `config.env` (the normal path — run this *after* `config.env` exists, see [`DEPLOYMENT.md`](DEPLOYMENT.md) Step 1 vs Step 2), then `us-west-1` as a last-resort default. This field genuinely can't be a `var.aws_region` reference — Terraform resolves backend configuration before any variables are evaluated at all, a real HCL limitation — so external patching is the only way it's ever kept correct.

State locking uses `use_lockfile = true` (native S3 conditional-write locking, Terraform >= 1.10 — see `required_version` in `versions.tf`) instead of a DynamoDB lock table. Two concurrent `terraform apply`s still can't corrupt state; there's just one fewer AWS resource to provision, pay for, and orphan on teardown. (`scripts/bootstrap-tf-state.sh` is the old S3+DynamoDB version of this bootstrap — deprecated, kept for reference only. Don't run it; it would create a DynamoDB table nothing in this repo references anymore.)

**If you skip this step**, Terraform silently falls back to local state (`.terraform/terraform.tfstate`), which is what makes `terraform plan` show "100 to add" even when a cluster is already running — the plan has no idea anything exists. Always check `terraform state list` before trusting a plan's resource count.

## Environments

`workspace_key_prefix` makes state workspace-aware without changing today's default behavior: the `default` workspace (what a plain `terraform apply` uses if you've never run `terraform workspace`) resolves to exactly `key` (`terraform.tfstate`), so nothing changes for the single-environment usage this project has always had.

To actually run a second, isolated environment:

```bash
terraform workspace new staging          # once
terraform workspace select staging       # every session after
cp environments/staging.tfvars.example environments/staging.tfvars   # gitignored, fill in real values
terraform apply -var-file=terraform.tfvars -var-file=environments/staging.tfvars
```

This gets `staging` its own state file (`environments/staging/terraform.tfstate` in the S3 bucket) automatically — no key values to hand-edit, no risk of two environments sharing one state and stomping each other's resources in Terraform's bookkeeping.

**What this does *not* solve:** almost every resource name in this project is a hardcoded `"bookstore-*"` literal (`aws_eks_cluster.this.name = var.cluster_name` defaults to `"bookstore-eks"`, `module.rds`'s `db_identifier = "bookstore-db"` in root `main.tf`, IAM role names, etc.), not derived from `terraform.workspace` or `var.environment`. State is correctly isolated per workspace, but two workspaces pointed at the *same AWS account* would still collide on the real AWS resource names the moment both tried to `apply` — `aws_eks_cluster` named `bookstore-eks` can only exist once per account+region, workspace or not. Safe today only because this project has only ever run one environment at a time. Parameterizing every hardcoded name by environment (e.g. `"${var.prefix}-${var.environment}-eks"`) is real, separate work — see [`FUTURE_IMPROVEMENTS.md`](FUTURE_IMPROVEMENTS.md) gap #17 — not something the backend change alone fixes.

## Module: `network`

VPC `170.20.0.0/16`, 2 public + 6 private subnets (see [`ARCHITECTURE.md`](ARCHITECTURE.md#subnet-layout) for exact layout), one Internet Gateway, **one** NAT Gateway (cost tradeoff — no per-AZ redundancy), an S3 Gateway VPC Endpoint (free — added 2026-08-14 so ECR image-layer pulls and S3 API traffic stop paying the NAT's data-processing fee), VPC Flow Logs to CloudWatch (90-day retention).

Notable: a `null_resource` with a `destroy`-time `local-exec` provisioner force-deletes the flow-log CloudWatch log group with a 15s sleep first. Why: AWS's VPC Flow Logs service self-heals its log group — if Terraform deletes the group while flow logs are still actively delivering, the service just recreates it, and then the VPC delete fails because a "foreign" log group exists that Terraform doesn't own. The `depends_on = [aws_flow_log.vpc]` ordering plus the sleep exists specifically to let in-flight delivery stop first. This was reverse-engineered from CloudTrail (`lookup-events` by `EventName`, not `ResourceName` — the latter returns nothing for this event type).

## Module: `security`

Two security groups: `alb_frontend` (80/443 from `0.0.0.0/0`, all egress) and `rds` (3306 from `var.eks_node_cidr_blocks` — the 4 EKS-node private subnet CIDRs specifically, **not** the whole VPC CIDR; a previous version of this rule really did open 3306 to all of `170.20.0.0/16`, including public subnets and RDS's own subnets, despite its `description` claiming EKS-nodes-only — see [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) OBS-049). RDS has **no egress rule** — it never initiates outbound connections, so one isn't needed (a `rds_egress` rule allowing `0.0.0.0/0` egress used to exist here and was removed as unnecessary blast radius).

## Root: ACM certificates

Not a module — despite older versions of this doc (and `ARCHITECTURE.md`) describing a `modules/acm` that doesn't actually exist in this codebase, and never did as far as `git log` on these files shows. **Two** real, separate ACM certificates live as plain resources at the root, in two different files, for two different consumers that can't share one certificate:

- **`cloudfront.tf`**'s `aws_acm_certificate.cloudfront` — wildcard SAN (`*.<domain>`), `count`-gated on `enable_cloudfront`, and hard-pinned to `us-east-1` (`provider = aws.us_east_1`) because that's a real, non-negotiable AWS requirement for any cert CloudFront uses, regardless of what region everything else runs in. Requests DNS validation but never actually completes it in Terraform (no `aws_acm_certificate_validation` resource) — harmless while CloudFront itself is disabled by default, but worth knowing if `enable_cloudfront` is ever flipped on for real.
- **`ingress-cert.tf`**'s `aws_acm_certificate.ingress` — same wildcard SAN, but regional (default provider, wherever the cluster actually is), and it *does* complete real DNS validation (`aws_route53_record.ingress_cert_validation` + `aws_acm_certificate_validation.ingress`) because the AWS Load Balancer Controller's certificate auto-discovery only matches already-ISSUED certs, not pending ones. This is the TLS cert the ALB actually terminates HTTPS with — see [`ARCHITECTURE.md`](ARCHITECTURE.md)'s ALB section for why no ARN from this ever gets injected into any Kubernetes manifest.

## Module: `rds`

MySQL 8.0, `db.t3.micro`, Multi-AZ, **gp3** storage (added 2026-08-14 — `aws_db_instance` defaults to gp2, cheaper/slower, if `storage_type` is left unset), 25GB storage (autoscaling to 100GB), 7-day backup retention, encrypted at rest (AWS-managed key by default). Admin credentials generated with `random_password` and stored in Secrets Manager at `/bookstore/db-credentials` (`recovery_window_in_days = 0` — force-delete on destroy, no 7/30-day soft-delete window, so repeated destroy/apply cycles during development don't collide on a pending-deletion secret name).

`performance_insights_enabled = false` — not supported on `db.t3.micro`, would hard-fail `terraform apply` if enabled. Enhanced Monitoring (`monitoring_interval = 60`) is separate and does work on this instance class.

`enabled_cloudwatch_logs_exports = ["error", "general", "slowquery"]` writes to 3 CloudWatch log groups (`/aws/rds/instance/<identifier>/<type>`) that RDS auto-creates with no expiry the first time it isn't Terraform-managed. Declared explicitly (`aws_cloudwatch_log_group.rds`, `retention_in_days = 30`, ordered via `depends_on` ahead of the DB instance) so retention is bounded from the first log line instead of needing a later import.

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

EKS 1.31, managed node group on `t3.medium` (min 1 / max 3 / desired 3 — desired was bumped from 1 to 2 because a single node hits its ENI pod-IP ceiling (~17 pods) before the full ArgoCD stack even fits (TF-014), then to 3 once all 5 microservices + api-gateway needed to schedule alongside the monolith and cluster-services (OBS-030)). The launch template's root volume is explicit `gp3`/20GB/encrypted (added 2026-08-14 — previously unset, silently defaulting to whatever the AL2 AMI ships with). The node group carries a `lifecycle.ignore_changes = [launch_template[0].version]` pin (OBS-051) — this account's EC2 vCPU quota (8) has no headroom for a rolling-replace surge node, so launch-template edits (including the volume change above) land in state but won't roll onto live nodes until the pin is removed post-quota-increase. `access_config.authentication_mode = "API_AND_CONFIG_MAP"` with explicit `aws_eks_access_entry`/`aws_eks_access_policy_association` resources granting cluster-admin to every ARN in `var.admin_principal_arns` (always includes whoever is running `terraform apply`, via `data.aws_caller_identity.current.arn`). This exists because EKS's `bootstrap_cluster_creator_admin_permissions` only fires once, at the literal `CreateCluster` API call — it doesn't retroactively grant access to a different person running `apply` later, and doesn't survive certain module refactors. The access-entry resources are the persistent, re-appliable equivalent.

An `aws_iam_openid_connect_provider` is created from the cluster's OIDC issuer — this is what makes IRSA (IAM Roles for Service Accounts) possible for everything downstream (External Secrets Operator, EBS CSI driver).

The node launch template's `user_data` runs `node-user-data.sh.tftpl` — a `templatefile()` render that installs `node-exporter` and `Fluent Bit` as systemd services (not DaemonSets — see [`ARCHITECTURE.md`](ARCHITECTURE.md#why-monitoring-runs-on-ec2-not-in-the-cluster) for why monitoring isn't in-cluster). **This file must be pure ASCII** — AL2's cloud-init uses Python 2.7's ASCII-only MIME parser, and a single non-ASCII character anywhere (even in a comment) silently kills the entire user-data script before the EKS bootstrap command ever runs, leaving nodes that boot but never join the cluster. This has broken the build three times; see TROUBLESHOOTING TF-009. `metadata_options` enforces IMDSv2 (`http_tokens = "required"`) with `http_put_response_hop_limit = 2` (containers on the node need one extra hop to reach IMDS versus the host itself).

## Module: `eks-addons`

Helm-installed cluster add-ons, all via `helm_release`:

| Chart | Namespace | Notes |
|---|---|---|
| external-secrets | `external-secrets` | ServiceAccount explicitly named `external-secrets-sa` with an IRSA role annotation — see below |
| aws-load-balancer-controller | `kube-system` | Replaces ingress-nginx (retired by the Kubernetes project 2026-03-31, see [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) OBS-057). IRSA-authenticated, provisions a real AWS ALB as a side effect of reconciling `Ingress` objects — invisible to Terraform (see destroy notes), the ALB is created/owned by the controller, not by any Terraform resource. |
| argocd | `argocd` | No `depends_on` (see below) |
| argo-rollouts | `argo-rollouts` | No `depends_on` (see below) |
| aws-ebs-csi-driver | (EKS addon, not Helm) | IAM policy attached to the node role first |

**cert-manager and ingress-nginx are both gone as of OBS-057** — cert-manager had exactly one consumer (the ingress TLS cert via its `ClusterIssuer`), and once ingress moved to the AWS Load Balancer Controller, TLS moved with it, to an ACM certificate the controller auto-discovers by hostname (see `ingress-cert.tf`, root). Neither chart does anything for this project anymore, so both were removed rather than left installed-and-unused.

**Every Helm chart in this module now installs concurrently.** They used to be partially serialized (`argocd` waited on `ingress-nginx`; `argo-rollouts` waited on `argocd`) as a resource-contention workaround from when the node group was a single `t3.medium` (see TF-001/TF-006). Once `node_desired_size` went to 2 (TF-014), that workaround was never revisited — the two remaining `depends_on` lines were pure leftover, not a real functional requirement (ArgoCD isn't exposed via ingress or TLS in this config, and Argo Rollouts is an unrelated project from ArgoCD). Removed to cut apply time; the critical path through this module is now roughly `max(all chart timeouts)` (ArgoCD's 900s) instead of the old serialized sum. **If a real apply on this node size starts hitting TF-001-shaped timeout failures again, the fix is re-adding explicit `depends_on` lines** in `modules/eks-addons/gitops.tf`, not scaling the node group further — this hasn't been verified against a real apply yet (see [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) OBS-006).

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

The actual MySQL schema + user creation is **not** Terraform's job — RDS doesn't expose a Terraform-native way to run arbitrary SQL. That happens via a Kubernetes Job (`k8s/services/catalog-service/base/schema-init-job.yaml`), run automatically by ArgoCD as a `PreSync` hook against the admin credentials — no manual step. See [`KUBERNETES.md`](KUBERNETES.md#the-schema-init-job--an-argocd-presync-hook-not-a-manual-one-off) and [`DEPLOYMENT.md`](DEPLOYMENT.md).

## Root: `argocd.tf`

Three things, none of which used to be automated:

1. **`kubectl_manifest` resources** applying `k8s/argocd/appproject.yaml`, `k8s/argocd/application.yaml`, and `k8s/argocd/applicationset-microservices.yaml` as-is (`file()`, not re-expressed as HCL) — replaces a manual `kubectl apply -f` step. Uses the `gavinbunney/kubectl` provider specifically because its `kubectl_manifest` resource defers schema validation to apply time; `hashicorp/kubernetes`'s `kubernetes_manifest` needs the target CRD to already exist at `plan` time, which breaks here since the `Application`/`ApplicationSet`/`AppProject` CRDs are installed by the `argocd` Helm release within the *same* apply. All three depend on `module.eks_addons`; `argocd_application` and `argocd_applicationset_microservices` additionally depend on `kubectl_manifest.argocd_appproject`, since ArgoCD rejects an Application naming a project that doesn't exist yet. `appproject.yaml` genuinely was left out of this file for a while — invisible on a long-lived cluster (the AppProject just sits there once created), it only became a real outage on the next from-scratch `terraform destroy` + `apply` cycle (OBS-058).

2. **`null_resource.wait_for_alb_hostname`** — a two-stage wait, more involved than it used to be (see OBS-057). First, a plain retry loop (`kubectl get ingress bookstore-ingress -n bookstore`, up to 5 minutes) polls for the `bookstore-ingress` Ingress object to exist at all — it's deployed by ArgoCD, asynchronously, not created directly by this apply, and `kubectl wait` needs its target to already exist or it fails immediately rather than waiting gracefully. Then `kubectl wait --for=jsonpath='{.status.loadBalancer.ingress[0].hostname}'` against that Ingress, because the AWS Load Balancer Controller reconciling it and actually provisioning the ALB can lag well behind the Ingress object's own creation. Re-runs every apply (`triggers = { always_run = timestamp() }`) — cheap once the condition is already true, and re-validates after a cluster recreate.

3. **`data "kubernetes_ingress_v1" "bookstore"`** — reads the now-confirmed-populated hostname off that same Ingress object's status, feeding `local.primary_alb_dns` (used by `module.route53` instead of `var.primary_alb_dns` directly). `var.primary_alb_dns` still works as a manual override if you explicitly set it; auto-discovery is only the fallback when it's empty. This replaces what used to be a required second `terraform apply` — see [`DEPLOYMENT.md`](DEPLOYMENT.md).

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
