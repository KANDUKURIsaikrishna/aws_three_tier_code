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

### OBS-005 — CI's `observability` branch trigger wasn't matched by the OIDC trust policy

`.github/workflows/ci-cd.yml`'s `build-and-push` job's `if` condition was updated to include `refs/heads/observability` so this branch could actually build/push images. `iam.tf`'s GitHub OIDC role trust policy — the thing that lets the job authenticate to AWS at all — was **not** updated to match; it still only trusts `refs/heads/main` and `refs/heads/improvements`. Until that trust policy is updated, this job will pass its own `if` check, get all the way to the "Configure AWS credentials" step, and fail there with an OIDC/AWS auth error that has nothing obviously to do with the branch-trigger change that actually caused it. Fix (not yet applied): add `"repo:${var.github_repo}:ref:refs/heads/observability"` to the `StringLike` condition's `sub` list in `iam.tf`.

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

## Related

- [`TERRAFORM.md`](TERRAFORM.md), [`KUBERNETES.md`](KUBERNETES.md), [`CICD.md`](CICD.md), [`DEPLOYMENT.md`](DEPLOYMENT.md)
- [`FUTURE_IMPROVEMENTS.md`](FUTURE_IMPROVEMENTS.md) — OBS-005 and other known gaps that should get fixed properly rather than worked around
