# Troubleshooting

Real errors hit while building and running this project, with root causes and fixes. Numbered `TF-xxx`/`CI-xxx`/`K8S-xxx` for cross-reference. Earlier entries (TF-001 through CI-001) are preserved from this project's history because the failure modes are still live risks on this codebase — the fixes are already in the code, but the *reasons* they were needed are exactly the kind of thing that resurfaces after a refactor. Later entries are new, found while building the microservices platform on `observability`.

---

## TF-001 — Helm releases time out on a single-node cluster

**Symptom:** `helm_release` resources for argocd/ingress-nginx/kube-prometheus-stack hang past their timeout with `context deadline exceeded`.

**Root cause:** All Helm charts installing in parallel (Terraform's default) on one `t3.medium` (2 vCPU, 4GB RAM) pulling 20+ container images simultaneously saturates CPU/memory/network. Pods stay `Pending`/`ContainerCreating` past the timeout.

**Fix (historical):** Serialized installs via `depends_on` chains + raised timeouts. **Current state:** `node_desired_size` is now 2 (see TF-014), which removed the need for most of that serialization — cert-manager/external-secrets/ingress-nginx now install concurrently. If you ever scale back to 1 node, expect this to resurface.

---

## TF-002 — RDS Performance Insights unsupported on `db.t3.micro`

**Symptom:** `InvalidParameterCombination: Performance Insights not supported for this configuration.`

**Fix:** `performance_insights_enabled = false` in `modules/rds/main.tf`. Enhanced Monitoring (`monitoring_interval = 60`) is unaffected and does work on this instance class — don't confuse the two.

---

## TF-003 — Secrets Manager secret exists but isn't in Terraform state

**Symptom:** `ResourceExistsException: /bookstore/db-credentials already exists` on `terraform apply`.

**Root cause:** A previous apply created the secret but state was lost (empty S3 backend strings — see [`TERRAFORM.md`](TERRAFORM.md#backend-state)) before it got recorded.

**Fix:**
```bash
terraform import module.rds.aws_secretsmanager_secret.db_credentials /bookstore/db-credentials
```
`make import` runs this (and the Grafana equivalent) automatically, no-op-safe on a fresh account.

---

## TF-004 — ACM `ignore_changes` redundant-element warning

Harmless. `domain_validation_options` is provider-computed; `ignore_changes` on it is a no-op that Terraform warns about every single plan/apply. Not fixed — low priority, doesn't block anything. See [`FUTURE_IMPROVEMENTS.md`](FUTURE_IMPROVEMENTS.md).

---

## TF-005 — Helm release shows "created but has a failed status"

**Root cause:** The Helm provider marks a release as created in state even if pods never became `Ready` before timeout.

**Fix:** `helm uninstall <release> -n <namespace>` + `terraform state rm module.eks_addons.helm_release.<name>` + re-apply. TF-001's serialization prevents this from recurring in practice.

---

## TF-006 — kube-prometheus-stack still times out even after serialization

**Root cause:** Even serialized, ~6 pods (Prometheus, Grafana, Alertmanager, kube-state-metrics, node-exporter, operator) at ~800MB RAM overwhelms a single `t3.medium`.

**Fix — architecture change, not a config tweak:** moved monitoring entirely off EKS onto a dedicated EC2 instance (`modules/monitoring-ec2`) running Docker Compose. `node-exporter`/`Fluent Bit` became systemd services on the node launch template instead of DaemonSets. Freed ~950MB RAM on the node, zero monitoring pods in the cluster now. Full detail: [`ARCHITECTURE.md`](ARCHITECTURE.md#why-monitoring-runs-on-ec2-not-in-the-cluster).

---

## TF-007 — RDS cross-region backup replication needs an explicit KMS key

**Symptom:** `InvalidParameterValue: Encrypted instances require a valid KMS key ID.`

**Root cause:** AWS-managed encryption keys are region-scoped and can't back cross-region backup replication — only a customer-managed KMS key (CMK) with a cross-region-capable policy works.

**Fix:** `dr.tf`'s replication resource is gated on `count = var.dr_kms_key_id != "" ? 1 : 0`. Leave `dr_kms_key_id = ""` (default) to skip replication entirely; RDS's normal same-region automated backups (7-day retention) still run regardless.

---

## TF-008 / K8S-001-003 — Post-migration security audit findings

Not errors — a proactive audit after the EC2 monitoring migration found and fixed:
- **K8S-001:** MySQL StatefulSet probes had `timeoutSeconds: 1` (default), too tight under write load, causing spurious liveness-triggered restarts. (Moot now — the StatefulSet is dead code, RDS is the real DB. Historical.)
- **K8S-002:** Backend base manifest had no `resources` block at all — only the prod overlay patched it in, so dev ran with zero CPU/memory limits.
- **TF-008:** `modules/security` had an `rds_egress` rule allowing `0.0.0.0/0` — RDS never initiates outbound connections, so this was unnecessary blast radius. Removed.
- **K8S-003:** ingress-nginx had no PodDisruptionBudget — a `kubectl drain` could evict the only ingress pod and drop all external traffic. Fixed via `controller.podDisruptionBudget.minAvailable: 1`.

---

## CI-001 — Semgrep blocks CI with 29 findings

**Findings:** 1 `gha-workflow-env-secret`, 25 `github-actions-mutable-action-tag`, 1 `ec2-imdsv1-optional` (EKS launch template), 1 each `aws-ec2-has-public-ip`/`ec2-imdsv1-optional` (monitoring EC2).

**Fixes applied:**
1. Moved `ECR_REGISTRY` (which embeds `secrets.AWS_ACCOUNT_ID`) from workflow-level `env:` (visible to every job, including untrusted PR code) to step-level `env:` on just the build step.
2. Pinned every third-party GitHub Action to its full 40-char commit SHA instead of a mutable tag (`@v4` → `@11bd71901bbe...  # v4.2.2`) — supply-chain hardening against a repointed tag.
3. Enforced IMDSv2 (`http_tokens = "required"`) on both the EKS node launch template (`hop_limit = 2` — containers need one extra hop past the host) and the monitoring EC2 (`hop_limit = 1`).
4. Suppressed `aws-ec2-has-public-ip` on the monitoring EC2 with an inline `# nosemgrep` comment — public IP is required by design (Grafana/Prometheus/Alertmanager UIs need direct access, scoped by `admin_cidr_blocks`).

**Gotcha worth remembering:** Semgrep anchors `aws-ec2-has-public-ip` to the `resource` declaration line, not the `associate_public_ip_address` attribute line. A `# nosemgrep` comment on the attribute line is silently ignored — it has to be on the `resource "aws_instance" "monitoring" {` line itself. Got this wrong once, shipped a fix that didn't fix it, caught on the next CI run.

---

## TF-009 — Unicode in node user-data crashes AL2 cloud-init

**Symptom:** EKS node group `CREATE_FAILED`, `NodeCreationFailure: Instances failed to join the kubernetes cluster`. EC2 console output: `UnicodeEncodeError: 'ascii' codec can't encode characters`.

**Root cause:** AL2's cloud-init uses Python 2.7's ASCII-only MIME parser. A single non-ASCII character *anywhere* in the MIME multipart user-data — including inside a shell comment — aborts cloud-init at the `init` stage before the EKS bootstrap command ever runs. The node boots, kubelet never starts, and the failure looks like a networking/IAM problem, not a text-encoding one. **This has broken the build three separate times.**

**Fix:** `modules/eks/node-user-data.sh.tftpl` must be pure ASCII, full stop. No `→`, no em-dashes, no smart quotes, nothing outside 0-127. If you're debugging a node that won't join and the EC2 console output mentions `UnicodeEncodeError` or a cloud-init `init` stage failure, check this file for stray Unicode before looking at IAM/SG/NAT — those are almost always the wrong lead here.

**Related gotcha:** Terraform also rejects bare `${VAR}` in `.tftpl` files unless the var is in the `templatefile()` vars map — anything else must be escaped as `$${VAR}` to survive Terraform's own interpolation before being handed to cloud-init.

---

## TF-010 — CloudWatch log group already exists outside state

Same shape as TF-003, different resource: `terraform import module.network.aws_cloudwatch_log_group.vpc_flow_logs /aws/vpc/flowlogs/bookstore`. Can't recur after a clean destroy+apply cycle — only shows up after a partial/interrupted apply.

---

## TF-011 — EKS node group stuck `CREATE_FAILED`

**Root cause:** A `CREATE_FAILED` node group can't transition to `ACTIVE` — it has to be destroyed and recreated, and Terraform's default retry logic just waits on the existing failed group and times out instead of replacing it.

**Fix:** `terraform apply -replace=module.eks.aws_eks_node_group.this`, or delete manually via `aws eks delete-nodegroup` and re-apply. **In practice this was almost always downstream of TF-009** — fix the user-data encoding first, the node group usually then creates cleanly on retry.

---

## TF-012 — Secrets Manager "already scheduled for deletion"

**Symptom:** `InvalidRequestException: ... already scheduled for deletion` — distinct from TF-003's `ResourceExistsException` (that's a *live* secret; this is a *soft-deleted, pending-deletion* one).

**Root cause:** `recovery_window_in_days = 7` (the old default) meant a deleted secret's name stayed reserved for 7 days before AWS would let you recreate it under the same name.

**Fix:** `recovery_window_in_days = 0` on both `db_credentials` and `grafana_admin` secrets now — force-deletes immediately, no soft-delete window. Deliberate tradeoff for a project that gets destroyed/recreated often during development; a long-lived production secret would want the 7-day window back as an accidental-deletion safety net.

---

## TF-013 — Whoever runs `apply` doesn't automatically get cluster access

**Root cause:** EKS's `bootstrap_cluster_creator_admin_permissions` only fires once, at the literal `CreateCluster` API call. It doesn't retroactively grant access to a different person running `terraform apply` later, and doesn't survive certain module refactors that state-move the cluster resource without recreating it.

**Fix:** Explicit `aws_eks_access_entry`/`aws_eks_access_policy_association` resources in `modules/eks`, `for_each` over `var.admin_principal_arns` (which always includes `data.aws_caller_identity.current.arn` — whoever is running `apply`, automatically, every time).

---

## TF-014 — Node group can't fit ArgoCD, ENI IP ceiling

**Root cause:** `t3.medium` caps at ~17 pods per node (ENI IP address limit, not a CPU/memory limit). One node can't fit the full ArgoCD stack (server + repo-server + application-controller + redis, each with replicas) alongside everything else.

**Fix:** `node_desired_size = 2`. This also incidentally resolved most of TF-001's resource-contention issues, letting several Helm releases install concurrently instead of needing full serialization.

---

## TF-015 — CloudTrail S3 bucket delete fails, Secrets Manager recovery window blocks re-create

Two related destroy-time issues, same root shape as TF-012: `force_destroy = true` on the CloudTrail S3 bucket (it's versioned — an "empty" versioned bucket still has version markers that block a normal delete), and `recovery_window_in_days = 0` on both Secrets Manager secrets. Both fixed as part of the same "make destroy fully seamless" pass as TF-012.

---

## TF-017 — `terraform destroy` fails on ingress-nginx's NLB and the flow-log group

**Root cause:** `ingress-nginx`'s `LoadBalancer` service type provisions a real AWS NLB as a Kubernetes-cloud-controller side effect — Terraform never called the AWS API for it, so it's invisible to `terraform destroy` and blocks subnet deletion (`DependencyViolation`) unless removed first. Separately, the VPC Flow Logs service self-heals its destination log group (see [`TERRAFORM.md`](TERRAFORM.md#module-network)) if deleted while flow logs are still actively delivering.

**Fix:** Two `null_resource`s with `destroy`-time `local-exec` provisioners — one runs `kubectl delete svc ingress-nginx-controller` + a 30s wait before the VPC teardown proceeds, the other force-deletes the flow-log CloudWatch group with a `depends_on = [aws_flow_log.vpc]` ordering + 15s sleep so in-flight delivery stops first. Both are best-effort (`|| true` on every command) — a missing `kubectl`/`aws` binary or an already-gone cluster never blocks the rest of the destroy.

---

## TF-019 — Network drop mid-`apply` recovery

If your connection drops mid-apply (laptop sleeps, wifi drops, SSH session to a remote runner dies), Terraform's local state may be left in an inconsistent "in progress" state without a clean lock release. Recovery: `terraform force-unlock <lock-id>` (the error message on the next `plan`/`apply` gives you the lock ID), then `terraform plan` to see what Terraform *thinks* changed versus what's actually live in AWS before blindly re-applying — a resource can be fully created in AWS but not yet recorded in state if the drop happened right after the API call succeeded but before Terraform wrote state.

---

## Observability-branch findings (new, found while building the microservices platform)

### OBS-001 — External Secrets Operator had zero IRSA wiring (found and fixed)

**Symptom (would have been):** every `ExternalSecret` in the cluster — old `db-secret` included — permanently stuck unable to sync, `SecretSyncedError`.

**Root cause:** `modules/eks-addons/external-secrets.tf` installed the ESO Helm chart with no IAM role, no ServiceAccount name override, no annotation — even though `k8s/base/secrets/external-secret.yaml`'s `ClusterSecretStore` already hardcoded a reference to a ServiceAccount named exactly `external-secrets-sa`. The chart's default SA name doesn't match that, and even if it did, there was no IRSA role for it to assume. This is a **pre-existing bug that predates the microservices work** — it would have silently broken the original monolith's secret sync too, discovered only because building a second service required reasoning carefully about the secrets path.

**Fix:** Added a proper IRSA trust-policy role scoped to `/bookstore/*` in Secrets Manager, and explicit `serviceAccount.name`/`serviceAccount.annotations` Helm `set` values so the chart creates the SA under the exact name and IRSA annotation the existing `ClusterSecretStore` expects. Commit `a87a10f`.

### OBS-002 — OIDC provider URL scheme breaks IRSA trust conditions (caught in code review, never shipped)

**Symptom (would have been):** `AssumeRoleWithWebIdentity` denied for every pod trying to use the IRSA role from OBS-001 — the exact fix above, silently defeated.

**Root cause:** `module.eks.oidc_provider_url` always returns the issuer URL *with* the `https://` scheme attached (`aws_iam_openid_connect_provider.eks.url`, sourced from `aws_eks_cluster.this.identity[0].oidc[0].issuer`). STS populates the federated-JWT trust-condition context keys *without* the scheme (`oidc.eks.us-west-1.amazonaws.com/id/XXXX:sub`, not `https://oidc.eks.../XXXX:sub`). A `StringEquals` condition built with the raw URL therefore checks a condition key STS never actually populates, and the trust policy never matches — a well-known Terraform IRSA footgun, but easy to miss on a first pass since nothing about it is a syntax error; `terraform validate` and even `terraform apply` succeed cleanly. It only fails at runtime, as an opaque AWS auth denial with no obvious connection to a URL string.

**Fix:** `replace(var.oidc_provider_url, "https://", "")` at the point of use in both the `:sub` and `:aud` condition variables. Caught by an independent code-quality review pass before this ever touched real infrastructure — see [Plan 1's Task 0 review](superpowers/plans/2026-07-30-catalog-service.md).

### OBS-003 — Schema-init Job heredoc quoting silently drops password interpolation (caught in code review, never shipped)

**Symptom (would have been):** `catalog-schema-init` Job reports success (no MySQL syntax error), but every pod trying to connect as `catalog_user` with the real generated password gets `ER_ACCESS_DENIED_ERROR` — and the Job itself gives no indication anything is wrong.

**Root cause:** `k8s/services/catalog-service/bootstrap/schema-init-job.yaml`'s SQL heredoc (this file has since moved to `base/schema-init-job.yaml` and become an ArgoCD PreSync hook — see [`KUBERNETES.md`](KUBERNETES.md#the-schema-init-job--an-argocd-presync-hook-not-a-manual-one-off) — the bug and fix described here predate that move) used a **quoted** delimiter (`<<'SQL'`), which disables *all* shell variable expansion inside the body, not just command substitution. The `CREATE USER ... IDENTIFIED BY '$CATALOG_DB_PASSWORD'` line therefore set the MySQL user's password to the **literal 21-character string** `$CATALOG_DB_PASSWORD`, not the real value from the env var — while the Deployment's `DB_PASSWORD` (via the real ExternalSecret) carries the actual random password. These would never match. The Job's own success criteria (exits 0, no SQL error) can't catch this — the SQL is syntactically valid, it just doesn't do what it looks like it does.

**Fix:** Unquote the heredoc delimiter (`<<SQL`, no quotes) so `$CATALOG_DB_PASSWORD` expands normally. Verified no other `$`-prefixed content in that SQL body would unintentionally expand as a side effect before applying the fix. Caught in the same code-quality review pass as OBS-002, before Task 9 (real deployment) ever ran.

### OBS-004 — `terraform plan` showing "100 to add" doesn't mean 100 new resources

Not a bug — a process trap. If you skip Terraform state bootstrap (see [`TERRAFORM.md`](TERRAFORM.md#backend-state)) or run `plan` from a checkout with fresh/empty local state, the plan will show every single resource as new — including ones already live in AWS under a different state backend. A stale local `kubectl` context showing a cluster ARN is **not evidence the cluster exists** — always independently verify with `aws eks describe-cluster --name <name>` before trusting either the plan output or a cached kubeconfig. This exact scenario happened while preparing to verify catalog-service: `kubectl config current-context` showed a live-looking `bookstore-eks` ARN, but the cluster had actually been destroyed; only `aws eks describe-cluster` (returning `ResourceNotFoundException`) revealed the truth.

### OBS-005 — CI's `observability` branch trigger wasn't matched by the OIDC trust policy ✅ RESOLVED

`.github/workflows/ci-cd.yml`'s `build-and-push` job's `if` condition was updated to include `refs/heads/observability` so this branch could actually build/push images. `iam.tf`'s GitHub OIDC role trust policy — the thing that lets the job authenticate to AWS at all — was **not** updated to match; it still only trusted `refs/heads/main` and `refs/heads/improvements`.

**Fix:** added `"repo:${var.github_repo}:ref:refs/heads/observability"` to the `StringLike` condition's `sub` list in `iam.tf`. Requires a `terraform apply` to actually take effect (IAM trust policy, not something `kubectl`-adjacent).

**How this was actually confirmed as a real, current blocker rather than closed by inspection alone:** while diagnosing `bookstore`'s `frontend` pods stuck `ImagePullBackOff` (no real images ever pushed to ECR on this branch), `gh run list --branch observability` showed every CI run on this branch as `completed failure` — but the actual failure was OBS-013's Semgrep finding at the `sast` stage, which runs *before* `build-and-push` and would have masked this exact bug even after fixing it, since the pipeline never got far enough to reach the AWS auth step. Fixed both in the same pass; this fix specifically addresses what happens once `sast` passes and `build-and-push` actually runs.

### OBS-006 — Removed two Terraform `depends_on` chains to shorten `apply` time (not yet verified against a real apply)

**What changed, and why:** three edits to cut the critical path of a fresh `terraform apply`:

1. `main.tf`'s `module "monitoring_ec2"` call had `depends_on = [module.eks_addons]` — a blanket wait on every Helm chart in `eks-addons` (up to 900s for ArgoCD alone), even though `monitoring-ec2` only actually needs `module.eks`'s outputs and the fast `grafana_admin` Secrets Manager entry (a `random_password` + two `aws_secretsmanager_secret*` resources, not gated on any Helm install). Removed — the real dependency on the Grafana secret is already expressed via the direct output reference (`grafana_admin_secret_arn = module.eks_addons.grafana_admin_secret_arn`), so Terraform still waits for exactly that one resource, not the whole module.
2. `modules/eks-addons/gitops.tf`'s `argocd` had `depends_on = [helm_release.ingress_nginx]`. Removed.
3. Same file's `argo_rollouts` had `depends_on = [helm_release.argocd]`. Removed.

Both (2) and (3) were leftover from the single-node resource-contention era (TF-001/TF-006) — they predate `node_desired_size` going to 2 (TF-014) and were never revisited after that fix landed. Neither chart has a real functional dependency on the other: ArgoCD isn't configured with `ingress.enabled` or any TLS/certificate integration in this Helm `set` block, so it has no resource-level reason to wait on ingress-nginx; Argo Rollouts is a separate CRD/controller from ArgoCD with no shared resources either.

**Why this is flagged as a troubleshooting entry, not just a changelog line:** this is exactly the shape of change that caused TF-001 and TF-006 in the first place — more Helm charts installing concurrently on a resource-constrained node. The mitigating fact is the node group is now 2×`t3.medium` instead of 1×, which is the actual fix that resolved those incidents; this change is a bet that the same fix leaves enough headroom for the previously-serialized charts too. **It has not been verified against a real `terraform apply`** (Task 9 of the microservices plan is on hold — see [Plan 1](superpowers/plans/2026-07-30-catalog-service.md)).

**If a real apply hits TF-001-shaped timeout failures after this change:** re-add both `depends_on` lines in `modules/eks-addons/gitops.tf` (`argocd` → `[helm_release.ingress_nginx]`, `argo_rollouts` → `[helm_release.argocd]`). Do not reflexively scale the node group further first — confirm the timeout is actually resource contention (check `kubectl top nodes`/`kubectl describe pod` for `Pending`/`Insufficient cpu` events during the failing apply) before assuming that's the cause.

### OBS-007 — Moving manual `kubectl` steps into Terraform/ArgoCD (`argocd.tf`, PreSync hook)

Three previously-manual `DEPLOYMENT.md` steps got automated: applying `k8s/argocd/application.yaml`/`applicationset-microservices.yaml` (now `kubectl_manifest` resources in `argocd.tf`), the second `terraform apply` for the ALB hostname (now a `data "kubernetes_service"` read gated behind a `null_resource` `kubectl wait`), and the catalog-service schema bootstrap (now an ArgoCD `PreSync` hook). None of this touched `.github/workflows/ci-cd.yml` — CI still never gets `kubectl`/cluster access, by design (see [`CICD.md`](CICD.md)); these steps moved into Terraform/ArgoCD, the tools that already had the access, not into CI.

**Two real gotchas hit while building this, both caught before anything ran for real:**

1. **`hashicorp/kubernetes`'s `kubernetes_manifest` resource was the first approach tried, and it's the wrong tool for this specific job.** It validates the target CRD's schema at `plan` time, which fails on a from-scratch apply where the `Application`/`ApplicationSet` CRDs don't exist yet at plan time — they're installed by the `argocd` Helm release *within the same apply*. Switched to `gavinbunney/kubectl`'s `kubectl_manifest` instead, which defers validation to apply time and has none of this chicken-and-egg problem. If you're tempted to add more Terraform-managed custom resources later (for `user-service`, `order-service`, etc.), use `kubectl_manifest`, not `kubernetes_manifest`, for the same reason.
2. **Converting the schema-init Job to an ArgoCD PreSync hook and adding it to `base/kustomization.yaml` silently broke its network access at first pass** — the namespace's `default-deny-all` NetworkPolicy only has an allow-egress exception for pods labeled `app: catalog-service`, and a bare Job's pod template doesn't get that label by default. Caught by re-reading `network-policy.yaml` before considering the change done, not by a failed apply. Fixed by adding `spec.template.metadata.labels.app: catalog-service` to the Job. Worth checking for the same NetworkPolicy label-matching gap on any future PreSync/PostSync hook Jobs in a namespace with a default-deny policy.

**Not yet verified against a real apply** — same caveat as OBS-006, Task 9 is on hold.

### OBS-008 — `Invalid count argument` on `aws_route53_record.primary` (caught by a real `terraform plan`) ✅ RESOLVED

**Symptom:**
```
Error: Invalid count argument
  on modules/route53/main.tf line 40, in resource "aws_route53_record" "primary":
  40:   count   = !var.enable_cloudfront && var.primary_alb_dns != "" ? 1 : 0
The "count" value depends on resource attributes that cannot be determined
until apply, so Terraform cannot predict how many instances will be created.
```

**Root cause:** OBS-007's ALB auto-discovery made `primary_alb_dns` (as passed into `module.route53`) sourced from `data.kubernetes_service.ingress_nginx`'s status, which is unknown at `plan` time on a fresh apply (the data source itself is gated behind `null_resource.wait_for_alb_hostname`, deferring the read to apply time). `aws_route53_record.primary`'s `count = !var.enable_cloudfront && var.primary_alb_dns != "" ? 1 : 0` needs to evaluate `primary_alb_dns != ""` to compute `count`, and Terraform categorically cannot compute `count`/`for_each` against a value that isn't known until apply — this is a hard Terraform limitation, not a bug in the data source or the null_resource.

`aws_route53_record.primary_cf` had the identical structural bug (`var.enable_cloudfront && var.primary_alb_dns != "" && var.cloudfront_domain != ""`) but didn't surface it in this plan — with `enable_cloudfront` defaulting `false`, `false && (unknown)` short-circuits to a statically-known `false` without needing to resolve the unknown operand. It would have broken the same way the moment anyone set `enable_cloudfront = true`.

**Fix:** Removed `var.primary_alb_dns != ""` from both `count` expressions (`modules/route53/main.tf`) — gate only on `enable_cloudfront`/`cloudfront_domain`, both plain vars that stay known at plan time. Safe because `null_resource.wait_for_alb_hostname` (no `|| true` on its `local-exec`, unlike this repo's destroy-time cleanup null_resources) already hard-fails the whole apply if the NLB hostname never appears — by the time `aws_route53_record.primary` actually applies, `records = [var.primary_alb_dns]` is guaranteed non-empty, so there's no real scenario left where skipping this record on emptiness was doing useful work. Verified against a real `terraform plan`: `Plan: 104 to add, 0 to change, 0 to destroy`, no errors.

**General lesson:** any value that flows through a `depends_on`-gated data source (deferred-to-apply-time reads, the whole point of that pattern — see OBS-007's ALB discovery) can never safely appear inside a `count`/`for_each` condition anywhere downstream, even indirectly through a module boundary. Grep for `count.*var\.` or `for_each.*var\.` on any variable whose value now originates from a data source before wiring one up.

### OBS-009 — CNAME not permitted at zone apex ✅ RESOLVED

**Symptom**, hit on the same real `terraform apply` that surfaced OBS-008 (the first one this project ever completed against a fresh account):
```
Error: creating Route53 Record: operation error Route 53: ChangeResourceRecordSets,
  ... InvalidChangeBatch: [RRSet of type CNAME with DNS name b17facebook.xyz.
  is not permitted at apex in zone b17facebook.xyz.]
  with module.route53.aws_route53_record.primary[0]
```

**Root cause:** `aws_route53_record.primary` pointed `var.domain` (the bare apex, e.g. `b17facebook.xyz`, not a subdomain) directly at the NLB hostname with `type = "CNAME"`. DNS forbids a CNAME at the zone apex — the apex needs NS/SOA records too, and a CNAME must be the *only* record for its name, which is incompatible. This is a genuine DNS-protocol-level restriction, not an AWS quirk, and not something this session's changes introduced — it's a **pre-existing bug that simply never got apply-tested before now**, since Task 9 (real deployment) was on hold for this entire project until this apply.

**Fix:** Route53's ALIAS record type — AWS-specific, behaves like a CNAME but is legal at the apex. `modules/route53/main.tf`'s `primary` and `primary_cf` records switched from `type = "CNAME"` + `records`/`ttl` to `type = "A"` + an `alias` block. The NLB's hosted zone ID comes from `data "aws_lb_hosted_zone_id" { load_balancer_type = "network" }` (region-correct, not hardcoded — resolved to `Z24FKFUX50B4VW` for us-west-1 on this apply); CloudFront's is the fixed, AWS-wide constant `Z2FDTNDATAQYW2` (same in every account and region — [AWS docs](https://docs.aws.amazon.com/general/latest/gr/cf_region.html)).

`aws_route53_record.secondary` (DR failover) was **left as CNAME**, deliberately — it's unreachable today (`count = 0`, no secondary-region EKS cluster/NLB exists yet, see [`ARCHITECTURE.md`](ARCHITECTURE.md#region-layout)) and fixing it correctly needs a secondary-region-scoped `hosted_zone_id` lookup this module doesn't have provider wiring for. Don't copy the CNAME pattern for it once `secondary_alb_dns` becomes real — give it the same ALIAS treatment, pointed at the *secondary* region's NLB zone ID, not the primary one.

Verified against the real, partially-applied stack (RDS, secrets, and the private RDS DNS record already existed from the failed apply): `terraform plan` came back clean, `Plan: 5 to add, 0 to change, 1 to destroy` — the one "destroy" is `null_resource.wait_for_alb_hostname` replacing itself (its trigger is `timestamp()`, by design, re-checked every apply — it's not a real AWS resource, "destroying" it does nothing).

**Update:** the ALIAS mechanism described here was correct, but the hosted zone ID it used (`load_balancer_type = "network"`, i.e. NLB) was not — the actual `terraform apply` that ran this failed with a *different* error immediately after. See OBS-010: the ingress LB in this cluster is a Classic ELB, not an NLB.

### OBS-010 — Wrong LB type: it's a Classic ELB, not an NLB ✅ RESOLVED

**Symptom**, hit immediately after OBS-009's fix, on the very next real `terraform apply` attempt:
```
Error: creating Route53 Record: operation error Route 53: ChangeResourceRecordSets,
  ... InvalidChangeBatch: [Tried to create an alias that targets
  a78c183ae42d84e9eb81e1cea4dd6cfc-2044134075.us-west-1.elb.amazonaws.com.,
  type A in zone Z24FKFUX50B4VW, but the alias target name does not lie
  within the target zone]
  with module.route53.aws_route53_record.primary[0]
```

**Root cause:** this entire project — this session's own docs included ([`ARCHITECTURE.md`](ARCHITECTURE.md), [`DEPLOYMENT.md`](DEPLOYMENT.md), [`KUBERNETES.md`](KUBERNETES.md)) — has called ingress-nginx's `LoadBalancer` Service an "NLB" throughout. It isn't one. `modules/eks-addons` has no `aws-load-balancer-controller` Helm release, and `modules/eks-addons/ingress.tf` never sets the `service.beta.kubernetes.io/aws-load-balancer-type: nlb` annotation on the Service. On EKS, a plain `type: LoadBalancer` Service with neither of those provisions through the legacy in-tree AWS cloud provider, which defaults to a **Classic Load Balancer** — not ALB, not NLB. OBS-009's fix asked Route53 for the NLB's hosted zone (`Z24FKFUX50B4VW`), and AWS correctly rejected it: the real LB's DNS name genuinely doesn't belong to that zone.

Trying the obvious next fix — `data "aws_lb_hosted_zone_id" { load_balancer_type = "classic" }` — failed too, with a *third* real error: `expected load_balancer_type to be one of ["application" "network"], got classic`. `aws_lb_hosted_zone_id` only covers ELBv2 (ALB/NLB); it has no concept of the classic v1 ELB at all.

**Fix:** `aws_elb_hosted_zone_id` — a separate, no-argument data source specifically for Classic ELB, resolving correctly per-region via the module's default provider. For us-west-1 that's `Z368ELLRRE2KJ0`, a different constant from the NLB zone `Z24FKFUX50B4VW` used (incorrectly) in OBS-009. `modules/route53/main.tf`'s `data "aws_lb_hosted_zone_id" "nlb"` became `data "aws_elb_hosted_zone_id" "ingress_lb"`.

Verified against the real, partially-applied stack: `terraform plan` came back clean, `Plan: 2 to add, 0 to change, 1 to destroy` (same benign `null_resource.wait_for_alb_hostname` self-replace as OBS-009), no errors — and the plan output showed `alias.zone_id = "Z368ELLRRE2KJ0"`, confirming the corrected zone actually got picked up.

**Not fixed by this entry, flagged for later:** the "NLB" naming throughout this project's docs is now known-inaccurate and hasn't been corrected everywhere — [`ARCHITECTURE.md`](ARCHITECTURE.md), [`DEPLOYMENT.md`](DEPLOYMENT.md), [`KUBERNETES.md`](KUBERNETES.md), and [`TERRAFORM.md`](TERRAFORM.md) all still say "NLB" in places describing this same load balancer. A Classic ELB is also AWS's oldest, most limited load balancer type (no static IPs, weaker health-check/target-group model, being phased out in favor of ALB/NLB generally) — genuinely worth considering whether to fix the docs to say "Classic ELB" accurately, or fix the *infrastructure* instead (add the NLB annotation, or install `aws-load-balancer-controller`, so the LB this project has always claimed to have actually exists). See [`FUTURE_IMPROVEMENTS.md`](FUTURE_IMPROVEMENTS.md).

### OBS-011 — `application.yaml` targetRevision pointed at `main`, which has no `k8s/overlays` at all ✅ RESOLVED

**Symptom**, hit live once `argocd.tf`'s `kubectl_manifest` had actually created the `bookstore` Application (a real milestone — proved OBS-007's Terraform-managed ArgoCD bootstrap works):
```
[{"lastTransitionTime":"...","message":"Failed to load target state: failed to
generate manifest for source 1 of 1: rpc error: code = Unknown desc = Manifest
generation error (cached): k8s/overlays/prod: app path does not exist","type":"ComparisonError"}]
```
Sync status stuck at `Unknown` indefinitely — not transient, force-refreshing and force-syncing didn't help, because the underlying problem was real: the path genuinely doesn't exist at that revision.

**Root cause:** `k8s/argocd/application.yaml` (pre-existing file, unrelated to any of this session's other work) has `targetRevision: main`. Verified directly against GitHub (`git ls-tree -d origin/main -- k8s/overlays` returns nothing): `main` has never had the Kustomize `base`/`overlays` restructure at all — that only landed on `improvements` (and now `observability`). This file was seemingly never actually exercised against a real ArgoCD instance before — Task 9 (real deployment) was on hold for this project's entire history until this session.

**Fix:** Same pattern already used for `k8s/argocd/applicationset-microservices.yaml`: pin `targetRevision: observability` for now, with a comment flagging it needs to switch back to `main` once this branch merges *and* `main` actually gets the overlay structure (not just once it merges — those are two different conditions). Fixed both the committed file (so future `terraform apply` runs stay consistent) and the live `Application` object directly via `kubectl patch` (so it didn't require a full new `apply` cycle to take effect immediately).

**Separately worth noting:** a related discovery mid-diagnosis — `kubectl -n argocd patch application X --type merge -p '{"operation":{"sync":{}}}'` run twice in a row with an *empty* `sync: {}` body gets reported as `patched (no change)` the second time, because the JSON is byte-identical to what's already there — it does **not** trigger a new sync. Use `argocd.argoproj.io/refresh=hard` annotation plus a sync operation that actually differs (e.g. explicit `revision`/`prune` fields) to force a genuinely new attempt.

### OBS-012 — `ServiceMonitor`/`PrometheusRule` don't just do nothing, they block the ENTIRE sync ✅ RESOLVED

**Symptom**, hit immediately after OBS-011's fix got the `bookstore` Application resolving the right revision — sync status stuck at `OutOfSync` / health `Missing` across many retries, nothing in the `bookstore` namespace ever got created, not even the namespace itself:
```
one or more synchronization tasks are not valid. Retrying attempt #5 at 9:22AM.
...
Message: The Kubernetes API could not find monitoring.coreos.com/PrometheusRule for
  requested resource bookstore/bookstore-alerts. Make sure the "PrometheusRule" CRD
  is installed on the destination cluster.
Message: The Kubernetes API could not find monitoring.coreos.com/ServiceMonitor for
  requested resource bookstore/backend-monitor. ...
```

**Root cause:** `k8s/base/monitoring/servicemonitor.yaml` and `prometheus-rules.yaml` were already documented (`ARCHITECTURE.md`, `KUBERNETES.md`) as "inert" — CRDs for a Prometheus Operator that isn't installed in this cluster (Prometheus runs on a standalone EC2 instance instead, see `ARCHITECTURE.md`). "Inert" turned out to be the wrong mental model for what ArgoCD does with them: the Kubernetes API can't validate a resource whose CRD was never registered *at all*, and when 2 out of ~22 resources in a sync batch fail like that, **ArgoCD fails the whole sync operation**, not just those 2 — every other valid, perfectly-fine resource (the `Namespace`, `Deployment`, `Rollout`, `Ingress`, everything) stayed `OutOfSync` and uncreated right alongside them, retrying every ~20s and failing identically every time.

**Fix:** Removed both from `k8s/base/kustomization.yaml`'s `resources` list. Left `monitoring/analysis-template.yaml` in place — different CRD group entirely (`argoproj.io/v1alpha1`, from Argo Rollouts, which *is* installed) — confirmed it was never part of the `SyncFailed` set. `kubectl kustomize k8s/overlays/prod` still renders cleanly (22 resources across 15 kinds, no `PrometheusRule`/`ServiceMonitor`).

**General lesson:** "this CRD manifest is inert/does nothing" is only true until something (ArgoCD, `kubectl apply -f` on a whole directory, a CI validation step) tries to actually process it as part of a batch — at that point "does nothing" becomes "blocks everything in the same batch." [`FUTURE_IMPROVEMENTS.md`](FUTURE_IMPROVEMENTS.md) already flagged these two files as a gap to resolve; this is that resolution, forced by hitting it live rather than done proactively.

## Related

### OBS-013 — Schema-init PreSync hook ran before its own secrets existed ✅ RESOLVED

**Symptom**, hit live once OBS-012 unblocked the rest of the sync:
```
catalog-schema-init-rcpw7   0/1   CreateContainerConfigError
...
Warning  Failed  12m (x12 over 14m)  kubelet  spec.containers{schema-init}: Error: secret "admin-db-secret" not found
```
`kubectl get externalsecret -n catalog` / `kubectl get secrets -n catalog` both returned `No resources found` — the `admin-db-secret` and `catalog-db-secret` `ExternalSecret` objects had never even been created, 15 minutes in, despite being plain (non-hook) resources in the same kustomize base as the Job.

**Root cause:** a real ordering bug in this session's own PreSync-hook design (OBS-007/[`KUBERNETES.md`](KUBERNETES.md#the-schema-init-job--an-argocd-presync-hook-not-a-manual-one-off)). ArgoCD's sync has two entirely separate phases: `PreSync` hooks run **first**, then the normal `Sync` phase (everything without a hook annotation) runs after. `schema-init-job.yaml` was a `PreSync` hook, but `admin-db-secret.yaml`/`external-secret.yaml` (the `ExternalSecret`s it depends on) were plain `Sync`-phase resources — meaning the Job was guaranteed to run *before* the secrets it needs were ever created, not racing them, **always losing**. `kubectl describe application bookstore` never surfaced this as a sync error because from ArgoCD's perspective the hook was "Running: waiting for completion" exactly as designed — it just never could complete, because the thing it needed was scheduled for a phase that hadn't started yet.

**Fix:** made both `ExternalSecret`s `PreSync` hooks too, at `sync-wave: "-1"` (the Job stays at the implicit default wave `"0"`). ArgoCD runs hooks of the same type in ascending sync-wave order, so `-1` now genuinely completes before `0` starts — within the same `PreSync` phase, not racing across two different phases anymore.

**A second, independent bug found while fixing this:** the very next CI run failed at the Semgrep SAST stage (`yaml.kubernetes.security.allow-privilege-escalation-no-securitycontext`, blocking) — `schema-init-job.yaml`'s container had **no `securityContext` at all**, unlike literally every other container in this repo (`backend/rollout.yaml`, `catalog-service/deployment.yaml`, etc., all have `runAsNonRoot`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, dropped capabilities). Missed when the Job was first written because it was never run through CI until this point (Task 9 was on hold the whole time this file existed). Fixed by matching the exact posture used everywhere else in this repo, plus a `/tmp` `emptyDir` mount since `readOnlyRootFilesystem: true` means the `mysql` CLI needs somewhere writable for its own temp files.

**General lesson, same shape as OBS-012:** a hook or resource that *depends on* another resource needs that dependency to be in the **same or an earlier hook phase and sync-wave** — being in the same kustomize base is necessary but nowhere near sufficient for ordering guarantees. Check this explicitly for any future PreSync/PostSync hook that reads a Secret/ConfigMap.

## Related

### OBS-014 — Pinned `trivy-action` SHA broke via an unpinned transitive dependency ✅ RESOLVED

**Symptom**, hit on the CI run right after OBS-005/OBS-013 were fixed — first time `build-and-push` ever actually started on this branch:
```
##[error]Unable to resolve action `aquasecurity/setup-trivy@v0.2.1`, unable to find version `v0.2.1`
```
Failed at the generic "Set up job" step, before any of this workflow's own steps ran — nothing to do with our code, Docker, AWS, or Trivy's actual scan logic.

**Root cause:** `aquasecurity/trivy-action@915b19b...` (pinned, tagged `v0.28.0`) is a composite action whose own `action.yaml` calls `uses: aquasecurity/setup-trivy@v0.2.1` — by a **mutable tag**, not a hash. This repo pins its own direct action references to commit SHAs specifically to prevent exactly this class of problem (see CI-001) — but that protection doesn't extend through a composite action's *own* internal `uses:` lines, which are entirely outside this repo's control. At some point upstream, the `aquasecurity/setup-trivy` project deleted or moved the `v0.2.1` tag, and every consumer of that specific `trivy-action` version broke simultaneously, with no code change on this end.

**Fix:** bumped to `trivy-action@ed142fd...` (`v0.36.0`) in both `ci-cd.yml` (3 occurrences) and `terraform.yml` (1 occurrence, same stale pin, would have broken identically on its next run). Verified *before* bumping, not just assumed: fetched `v0.36.0`'s `action.yaml` directly (`gh api repos/aquasecurity/trivy-action/contents/action.yaml?ref=...`) and confirmed it pins `setup-trivy` by commit hash too (`aquasecurity/setup-trivy@3fb12ec... # v0.2.6`) — this version won't break the same way again, versus blindly bumping to whatever's newest and hoping.

**General lesson:** pinning a third-party Action to a commit SHA protects against that Action's tag being repointed, but says nothing about *that Action's own dependencies* — a composite action can still break out from under you if it references something else by a mutable tag internally. Periodically checking whether pinned actions have newer stable releases (not just reactively, after a break) would catch this class of issue before it blocks a real deploy.

## Related

### OBS-015 — PreSync hook with only `HookSucceeded` gets stuck forever once it fails once ✅ RESOLVED

**Symptom:** after OBS-013's fix landed and a new image/tag round went out, `catalog-service`'s Application stayed `Running: waiting for completion of hook batch/Job/catalog-schema-init` indefinitely across multiple sync attempts and pushes — `kubectl get pods -n catalog` kept showing the exact same `catalog-schema-init-rcpw7` pod, unchanged, for over an hour, well past when the secrets that used to block it (OBS-013) were fixed.

**Root cause:** `argocd.argoproj.io/hook-delete-policy: HookSucceeded` only deletes the hook resource when it **succeeds**. This Job's very first run happened before OBS-013's fix landed, so it failed (`CreateContainerConfigError`) and was never cleaned up. Every sync attempt after that — including ones on commits that would have fixed the underlying secret-ordering problem — saw a same-name `Job` resource already existing in a non-terminal state and just kept waiting on *that one*, never deleting it and never creating a fresh attempt. A permanently-broken hook doesn't retry; it wedges the Application forever, silently, since ArgoCD reports this as "Running," not as an error.

**Fix:** `argocd.argoproj.io/hook-delete-policy: BeforeHookCreation,HookSucceeded` — `BeforeHookCreation` deletes whatever hook resource already exists (success or failure) right before creating a new one for the current sync attempt, which is what this Job's own idempotent-SQL design already assumed would happen. Also manually deleted the specific stuck Job to unblock immediately rather than waiting for another full push/CI/sync round.

**General lesson:** for any hook whose work is meant to be safely re-run every sync (idempotent SQL, idempotent API calls, etc.), `hook-delete-policy` needs `BeforeHookCreation` specifically — `HookSucceeded` alone is a trap that only reveals itself the first time the hook actually fails, which for something gating a fresh service's very first deploy is likely to be immediately.

### OBS-016 — `backend` Rollout: `InvalidSpec`, `AnalysisTemplate` metric with `interval` but no `count`, plus a dead in-cluster Prometheus address ✅ RESOLVED

**Symptom**, discovered while checking why `bookstore`'s `frontend` pods came up fine (new image pulled, `Running`) but `backend` had zero pods at all after 67 minutes:
```
Message: The Rollout "backend" is invalid: spec.strategy.canary.steps[1].analysis.templates:
  Invalid value: "error-rate": AnalysisTemplate error-rate has metric error-rate which runs
  indefinitely. Invalid value for count: <nil>
Phase: Degraded
```
An `InvalidSpec` Rollout creates **no pods, no ReplicaSet, nothing** — worse than a normal failing deployment, since there isn't even a failing pod to look at.

**Root cause, two independent bugs in the same file** (`k8s/base/monitoring/analysis-template.yaml`), neither ever caught because this Rollout+AnalysisTemplate combination had never been validated against a live Argo Rollouts controller before this session's Task 9:
1. The `error-rate` metric set `interval: 30s` but no `count` — Argo Rollouts requires a bounded number of measurements for an interval-based metric; without it, the metric "runs indefinitely," which Rollouts rejects outright as an invalid spec, not a runtime failure.
2. The Prometheus `address` pointed at `kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090` — an in-cluster Service name that hasn't existed since TF-006 moved monitoring to a standalone EC2 instance (see [`ARCHITECTURE.md`](ARCHITECTURE.md#why-monitoring-runs-on-ec2-not-in-the-cluster)). This one wouldn't have blocked the Rollout from creating pods (it's a runtime concern, not a spec-validity one), but the analysis step would have failed to connect the moment it actually ran, most likely aborting the canary.

**Fix:** added `count: 2` (roughly matches the Rollout's own pause durations at each analysis step), and pointed `address` at the real EC2 Prometheus (`terraform output prometheus_url`). The query's own `... or vector(0)` / `... or vector(1)` fallbacks mean it now returns a benign 0%-error-rate result even though the EC2 Prometheus doesn't actually scrape `nginx_ingress_controller_requests` yet (ingress-nginx metrics scraping was never wired up — ties into the observability-extension work already tracked in [`FUTURE_IMPROVEMENTS.md`](FUTURE_IMPROVEMENTS.md)). This unblocks the Rollout; it does not yet make the canary analysis meaningful — that's real follow-up work, not something papered over here.

## Related

### OBS-017 — `rds_endpoint` output includes the port, breaking every DB connection in this project's history — plus a shell backtick bug in the same failure

**Symptom**, hit once OBS-013/OBS-015 got the schema-init hook actually starting for the first time ever:
```
sh: line 2: desc: command not found     (×3)
mysql: [Warning] Using a password on the command line interface can be insecure.
ERROR 2005 (HY000): Unknown MySQL server host 'bookstore-db.cj4yg2wykia3.us-west-1.rds.amazonaws.com:3306' (-2)
```

**Root cause 1 (the big one):** `modules/rds/outputs.tf`'s `rds_endpoint` output was `aws_db_instance.db.endpoint` — the AWS/Terraform provider's `endpoint` attribute is `"host:port"` combined, not a bare hostname. Every consumer in this repo treats it as a bare hostname: the admin Secrets Manager entry's `DB_HOST` (`modules/rds/main.tf`), catalog-service's own `DB_HOST` (root `main.tf`), and the private Route53 zone's CNAME target (`modules/route53/main.tf`) — none of which can handle an embedded port. A DNS/driver hostname lookup on a string containing a colon fails outright, exactly as seen above. **This means no database connection anywhere in this project — old `backend/` included — has ever actually succeeded, for this project's entire history.** It was simply never exercised end-to-end (real RDS + real app pod + real credentials, all at once) until this session's Task 9.

**Fix, two separate places** (not one — checked, and the first instinct of "just fix the output" was wrong): `modules/rds/outputs.tf`'s `rds_endpoint` output changed to `aws_db_instance.db.address` — this fixes catalog-service's `DB_HOST` (root `main.tf`, references the output) and the Route53 private CNAME (`modules/route53/main.tf`, also references the output). But the **admin** Secrets Manager entry's `DB_HOST` (`modules/rds/main.tf`) builds its value directly from `aws_db_instance.db.endpoint`, never going through the module's own output at all — fixing the output alone leaves the admin secret (the one both the original `backend/` and the schema-init hook actually read) still broken. Fixed both, independently, both now use `.address`. Port continues to be handled the way it already was everywhere (a separate `DB_PORT` key/ConfigMap value, never derived from this output).

**Root cause 2 (found in the same failure, a different bug):** the three `sh: desc: command not found` lines came first, before the connection error — `schema-init-job.yaml`'s SQL heredoc is intentionally **unquoted** (`<<SQL`, not `<<'SQL'`) so `$CATALOG_DB_PASSWORD` expands (OBS-003's fix). An unquoted heredoc *also* treats bare backticks as shell command substitution, not literal characters — and the SQL has three `` `desc` `` MySQL-identifier-quoted column references. Each one ran as the shell command `desc` (which doesn't exist), silently stripping the identifier from the `CREATE TABLE`/`INSERT`/`SELECT` statements sent to MySQL. OBS-003's own fix note said "verified no other `$`-prefixed content would unintentionally expand" — true, but incomplete: it didn't check for backtick side effects, which are a separate unquoted-heredoc hazard.

**Fix:** escaped all three as `` \`desc\` `` — a backslash-escaped backtick is literal to the shell (not command substitution) while still reaching MySQL as a real backtick-quoted identifier. Verified locally before committing: a standalone shell simulation of the same heredoc structure confirmed `\`desc\`` renders as literal `` `desc` `` in the output *and* `$CATALOG_DB_PASSWORD` still expands correctly — both properties hold simultaneously.

**Status:** both fixes are committed. The `rds_endpoint` output change needs a real `terraform apply` to actually update the live Secrets Manager secret content — not yet run as of this entry. Not yet re-verified end-to-end after that apply.

**General lesson:** an unquoted heredoc is a much bigger commitment than "now `$VAR` expands" — it also activates backtick command substitution and (less commonly relevant here) other shell metacharacters. Any heredoc carrying SQL with backtick-quoted identifiers needs those backticks escaped the moment the heredoc stops being single-quoted, not just a scan for stray `$` signs.

## Related

### OBS-018 — Protected the public Route53 zone from destroy/recreate churn

Not a bug — an operational decision, recorded here because it changes destroy behavior and would otherwise be surprising the first time someone hits it.

**Context:** `aws_route53_zone.public` (zone ID `Z05284462VHV14S4GNFNS` as of this session) already exists from earlier applies this session, and its 4 AWS-assigned nameservers have already been manually copied to the domain's real registrar (GoDaddy) to delegate the domain to Route53 — a one-time, outside-Terraform step. This project also destroys and recreates its whole stack often during development (see TF-015/TF-017). If `terraform destroy` (or any operation forcing this specific resource to be replaced) ever tears down this zone, AWS assigns a **different** set of 4 nameservers on recreation — silently breaking the GoDaddy delegation until someone notices the domain stopped resolving and manually re-updates the registrar.

**Fix:** added `lifecycle { prevent_destroy = true }` to `aws_route53_zone.public` in `modules/route53/main.tf`. Scoped to just this one resource — RDS, EKS, and every record *inside* this zone still destroy/recreate freely; only the zone's own identity (and therefore the registrar delegation) is protected. Verified as a true no-op against the live, already-existing zone: `terraform plan` shows no changes to it.

**To intentionally redo DNS from scratch later:** remove the `lifecycle` block, `terraform apply` (removing `prevent_destroy` is itself a plan-time-only change, not a resource replacement), then `terraform destroy` will be able to remove the zone — followed by manually re-delegating the new NS values at the registrar again, same one-time step as before.

## Related

### OBS-019 — `prom-client` in `devDependencies`, missing from every production backend image ever built

**Symptom**, once OBS-017's DB_HOST fix finally let a real `terraform apply` land and the backend Rollout actually tried to start:
```
Error [ERR_MODULE_NOT_FOUND]: Cannot find package 'prom-client' imported from /app/app.js
Node.js v22.23.2
```
`backend` pod stuck in `CrashLoopBackOff` — not a DB issue at all, despite arriving right after a batch of DB-connectivity fixes.

**Root cause:** `backend/app.js` imports `prom-client` unconditionally at module load (the `/metrics` endpoint, added during this branch's observability work) — genuine runtime code, not a dev/test-only dependency. But `backend/package.json` listed it under `devDependencies`, and `backend/Dockerfile` builds with `npm ci --omit=dev`. Every production image built from this repo has therefore been missing the package the app can't start without. This had never been caught because the backend pod had never previously gotten far enough to hit a real `import` at process start — it was blocked first by OBS-005 (IRSA), then OBS-017 (DB_HOST) — this is the first time it actually ran.

**Fix:** moved `prom-client` to `dependencies` in `backend/package.json`, regenerated `backend/package-lock.json` via `npm install --package-lock-only` (flips the `dev` flag on `prom-client` and its own sub-dependency tree, e.g. `@opentelemetry/api`, `bintrees`, `tdigest`). Verified before committing: ran `npm ci --omit=dev` against the new lockfile in a clean tmpdir (mirrors the Dockerfile's `deps` stage exactly) and confirmed both that `node_modules/prom-client` exists and that `import('prom-client')` resolves.

**Status:** fixed and committed. Needs a new backend image — the currently-deployed tag (`1dc8bc38`) predates this fix. `observability` is a CI push-trigger branch (`.github/workflows/ci-cd.yml`), so pushing this commit builds one automatically; no manual `docker build`/`push` needed.

### OBS-020 — RDS has been empty this entire project's history; `test.books` was never created

**Symptom**, hit by the `catalog-schema-init` hook (which migrates from `test.books` into `catalog_db.books`) once OBS-017 let it actually reach RDS:
```
ERROR 1146 (42S02) at line 11: Table 'test.books' doesn't exist
```

**Root cause:** the schema+seed SQL (`CREATE DATABASE`/`CREATE TABLE books`/two seed `INSERT`s) has only ever existed in `k8s/base/database/mysql-init-configmap.yaml` — a ConfigMap mounted by the in-cluster MySQL StatefulSet (`mysql-statefulset.yaml`) that's dead code today (RDS replaced it, confirmed: neither file is referenced by `k8s/base/kustomization.yaml`'s `resources:` list). When the project migrated to RDS, this initialization SQL never got ported over — RDS has been provisioned and empty since. `backend/app.js`'s `/books` route only ever does `SELECT * FROM books`; nothing in the old monolith path ever issued a `CREATE TABLE`. Consistent with OBS-017's finding that no DB connection in this project's history had ever actually succeeded end-to-end before this session — the missing table was simply never reached.

**Fix:** added `k8s/base/database/schema-init-job.yaml`, an ArgoCD PreSync hook Job for the `bookstore` Application, following the exact pattern already proven for `catalog-service` (`k8s/services/catalog-service/base/schema-init-job.yaml`): same `hook-delete-policy: BeforeHookCreation,HookSucceeded` (OBS-015), same pod `securityContext`/container `securityContext` (Semgrep gate), same escaped-backtick heredoc approach for the `` `desc` `` column (OBS-017) — verified locally with the same capture-and-diff heredoc simulation before committing. Idempotent via `WHERE NOT EXISTS (SELECT 1 FROM test.books WHERE title = ...)` rather than catalog's `ON DUPLICATE KEY UPDATE`, since `books.title` has no unique constraint to key off of (unlike catalog's `id`-based migration).

Two supporting fixes needed alongside it:
- Labeled the hook pod `app: backend` — matches `network-policy.yaml`'s existing `backend-policy` `podSelector`, so its already-present egress rule to the RDS CIDR on port 3306 applies without writing a new NetworkPolicy.
- Added the same `argocd.argoproj.io/hook: PreSync` + `sync-wave: "-1"` annotation to `db-secret`'s `ExternalSecret` (`k8s/base/secrets/external-secret.yaml`) that catalog's `admin-db-secret`/`catalog-db-secret` already carry — without it this Job would hit the exact `CreateContainerConfigError` race OBS-013 already found and fixed once for catalog-service.

**Status:** fixed and committed, not yet verified against a real ArgoCD sync as of this entry.

## Related

- [`TERRAFORM.md`](TERRAFORM.md), [`KUBERNETES.md`](KUBERNETES.md), [`CICD.md`](CICD.md), [`DEPLOYMENT.md`](DEPLOYMENT.md)
- [`FUTURE_IMPROVEMENTS.md`](FUTURE_IMPROVEMENTS.md) — OBS-005 and other known gaps that should get fixed properly rather than worked around
