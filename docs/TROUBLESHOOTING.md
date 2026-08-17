# Troubleshooting

Real errors hit while building and running this project, with root causes and fixes. Numbered `TF-xxx`/`CI-xxx`/`K8S-xxx` for cross-reference. Earlier entries (TF-001 through CI-001) are preserved from this project's history because the failure modes are still live risks on this codebase — the fixes are already in the code, but the *reasons* they were needed are exactly the kind of thing that resurfaces after a refactor. Later entries are new, found while building the microservices platform on `observability`.

---

## Debug Commands Reference

Every command below was actually run to diagnose a real entry further down this file, not written speculatively. Grouped by tool. The point of this table isn't just "what to type" — it's *why that specific command, and not a more obvious-looking one* was the thing that actually surfaced the real root cause, since several entries below (OBS-004, OBS-023, OBS-067) exist specifically because a *plausible-looking* piece of state (a cached kubeconfig context, an assumption about what owns a resource) turned out to be wrong, and only one specific command caught it.

### `kubectl` — is the cluster's actual live state what you assume it is

| Command | Purpose | Real example |
|---|---|---|
| `kubectl config current-context` | Confirms which cluster `kubectl` is actually pointed at *before* trusting anything else it reports. A stale context can look completely healthy while pointing at a cluster that no longer exists. | OBS-004 — context showed a live-looking cluster ARN for one that had already been destroyed; only `aws eks describe-cluster` (below) caught the lie. |
| `kubectl get pods -n <namespace>` | The first, cheapest check of whether a workload's pods exist at all and what phase they're in (`Pending`/`CrashLoopBackOff`/`Running`). | OBS-013, OBS-015 — confirmed the exact same stuck pod name was being reused across many failed sync retries, not a fresh attempt each time. |
| `kubectl describe pod <name> -n <namespace>` | Pulls the pod's **Events** list — the only place Kubernetes records *why* a pod never scheduled or never became ready (quota rejections, image pull errors, failed admission). `kubectl get` alone never shows this. | OBS-021 — revealed a `ResourceQuota` rejecting every pod-create attempt for missing `resources` fields, something invisible from `get pods` (which showed nothing, since no pod was ever actually created). |
| `kubectl describe application <name> -n argocd` | ArgoCD's own CRD-level sync/health status and, critically, the specific per-resource error strings ArgoCD attaches when a sync fails (missing CRDs, hook timeouts). | OBS-011, OBS-012, OBS-013 — the `ComparisonError`/`SyncFailed` messages here are what pointed at a bad `targetRevision` and missing CRDs, respectively. |
| `kubectl logs -n <namespace> -l <label-selector>` | Reads a specific controller or operator's own logs when its *behavior* looks wrong but nothing about the Kubernetes object state explains why (an auth error, a stale-cache symptom). | OBS-030 (`external-secrets` logs showed the real `ClusterSecretStore not found` string), OBS-069 (`aws-load-balancer-controller` logs showed `UnauthorizedOperation` — the real signal that its IAM role had zero policies attached). |
| `kubectl get externalsecret -n <ns>` / `kubectl get secrets -n <ns>` | Confirms whether specific `ExternalSecret`/`Secret` objects were **ever created at all**, as opposed to created-but-failing-to-sync — two very different failure shapes that look identical from a crashing pod's perspective. | OBS-013 — both returned `No resources found`, proving the secrets were never created, not just slow to sync. |
| `kubectl top nodes` | Live CPU/memory pressure per node — the fast way to tell "this Helm timeout is real resource contention" from "this is something else," instead of guessing. | Referenced directly in OBS-006 as the check to run before assuming a timeout means the node group needs to grow again. |
| `kubectl kustomize <path>` | Renders the *fully resolved* manifest locally, with zero cluster or ArgoCD access needed — the exact same output ArgoCD would generate and apply. Lets you check "what SHOULD exist" independently of "what ArgoCD says it did." | OBS-012 (confirmed the fixed base has zero `PrometheusRule`/`ServiceMonitor` resources left), OBS-023 (proved the correct manifest really did exist at the target commit, isolating the bug to ArgoCD's own repo-server cache, not the repo). |
| `kubectl apply --dry-run=server -f <file>` | Submits a manifest for real server-side admission validation without creating anything — used here specifically to rule out a cluster-side admission webhook or a bad YAML as the cause of a field silently not applying. | OBS-023 — proved the manifest itself was fine (dry-run succeeded with the field populated), narrowing the bug to what ArgoCD specifically was submitting. |
| `kubectl get events -n <namespace>` | Cluster-level event stream for a namespace — catches things like `DeletingLoadBalancer` that happened *before* anyone was looking, letting you reconstruct a timeline after the fact. | OBS-052 — showed the LoadBalancer deletion events firing ~60 minutes before the outage was actually noticed. |
| `kubectl debug node/<name> -it --image=busybox -- chroot /host ...` | Gets an interactive shell on a worker node's real root filesystem without SSH or SSM access to the node itself — the fallback when neither is set up. | OBS-050 — the only way to run `systemctl status fluent-bit` on a node and discover it had never even been installed. |
| `kubectl rollout restart deployment <name> -n <namespace>` | Forces a Deployment's pods to restart immediately, bypassing whatever backoff/retry schedule its own reconcile loop is on — used after fixing an underlying cause (a missing IAM policy, a stuck cache) to get an *immediate* clean retry instead of waiting for the next scheduled one. | OBS-023 (`argocd-repo-server`, suspected but untested), OBS-069 (`aws-load-balancer-controller` — cleared both stuck `Ingress` finalizers within 15s of the restart). |
| `kubectl get svc -n <namespace>` | Confirms whether a specific `Service` object (not just its pods) still exists — catches the case where the workload is healthy but the thing that exposes it externally is gone. | OBS-052 — showed the LoadBalancer `Service` itself missing while its controller pod was still `Running`. |

### `aws` CLI — ground truth outside Terraform state and Kubernetes objects

| Command | Purpose | Real example |
|---|---|---|
| `aws eks describe-cluster --name <name>` | The one command that can't lie about whether a cluster actually exists — independent of a cached `kubeconfig`, independent of Terraform state. | OBS-004 — returned `ResourceNotFoundException` for a cluster `kubectl` still had a working-looking context for. |
| `aws ec2 describe-security-groups --filters ...` | Reads real, live security-group rules and tags directly — the only way to confirm a rule is (or isn't) actually present, versus what code/docs claim it should be. | OBS-027 (confirmed port 22 was never in the SG at all), OBS-067 (found the ALB controller's leftover shared backend SG by its `elbv2.k8s.aws/cluster` tag). |
| `aws ec2 describe-instances --filters "Name=tag:Name,Values=<name>"` | Confirms an EC2 instance's actual state (`running`/`stopped`/terminated) and, via its output, its private/public IPs — used both as a health check and as a runtime IP-discovery mechanism. | OBS-024 (confirmed the monitoring EC2 was `running` while its whole stack was unreachable — pointing at an app-level failure, not an infra one), OBS-050 (used *inside* node boot scripts to discover the monitoring EC2's private IP at runtime, sidestepping a circular Terraform module dependency). |
| `aws cloudtrail lookup-events --lookup-attributes AttributeKey=ResourceName,AttributeValue=<id>` | Reconstructs a resource's **real event history** — who created it, what called it, when — even after the resource itself is gone. The tool of last resort when you don't know what actually owns something. | OBS-067 — the only thing that overturned an unverified guess ("this must be EKS's own cluster SG") and proved it was actually the AWS Load Balancer Controller's own shared backend SG, via its `CreateLoadBalancer`/`AuthorizeSecurityGroupIngress` call history. |
| `aws secretsmanager get-secret-value` / `put-secret-value` | Reads or writes a secret's real, current value directly — bypassing whatever's supposed to be syncing it, to check if the sync is even the problem. | Used to confirm/repair Grafana admin and DB credential values independent of `ExternalSecret` sync status. |
| `aws route53 list-hosted-zones-by-name` / `list-resource-record-sets` / `get-hosted-zone` | Finds every hosted zone for a domain (not just the one Terraform manages) and reads a zone's actual record set or delegated nameservers — the only way to catch a second, un-managed zone existing alongside the real one. | OBS-026 — found a Terraform-unmanaged second zone whose nameservers were the ones GoDaddy actually delegated to, orphaning the "real" zone entirely. |
| `aws ssm describe-instance-information` | Checks whether the SSM agent is registered for an instance — the fast way to know *before* attempting a connection whether Session Manager is even a viable fallback to SSH. | OBS-024, OBS-050 — both returned empty, ruling out SSM and forcing SSH (OBS-024) or `kubectl debug node` (OBS-050) as the only remaining option. |
| `aws autoscaling describe-scaling-activities` | Shows an Auto Scaling Group's own recent scaling attempts and *why* each one succeeded or failed — surfaces AWS-side rejection reasons (like a quota) that never show up in Terraform's or EKS's own error text. | OBS-051 — revealed repeated `VcpuLimitExceeded` as the ASG tried and failed to add surge capacity for a node-group rolling update. |
| `aws service-quotas get-requested-service-quota-change` / `request-service-quota-increase` | Checks the status of, or files, an account-level limit increase — used once a quota (not application code) is confirmed as the actual blocker. | OBS-051 — requested a vCPU quota increase after confirming the account was already at its ceiling with zero headroom. |
| `aws iam list-role-policies --role-name <role>` | Lists what's **actually** attached to an IAM role right now — the ground truth check against an assumption that a `depends_on`/reference in Terraform guarantees a policy is attached before it's needed. | OBS-069 — returned zero policies, confirming the controller's pods really had started with no permissions at all, not just a slow-to-propagate one. |
| `aws acm describe-certificate` | Reads a certificate's real validation status and its DNS validation records directly from ACM. | Used while diagnosing ACM/Route53 validation-record issues (TF-004-adjacent, OBS-era ingress cert work). |
| `aws logs delete-log-group` | One-off manual cleanup of a CloudWatch log group Terraform doesn't (or no longer) manages. | Used for orphaned log groups outside state, same shape as TF-010. |

### `helm` — what actually got installed, independent of Terraform's belief about it

| Command | Purpose | Real example |
|---|---|---|
| `helm list -A` | Lists every Helm release across every namespace, straight from Helm's own release storage — the ground truth on what's actually installed in the cluster, regardless of what Terraform's `helm_release` state thinks happened. | Used to confirm a Helm uninstall had genuinely completed even when Terraform reported a timeout on the same operation (a false-alarm shape covered in OBS-029 and the destroy-time `helm_release` timeout entries). |
| `helm get manifest <release> -n <namespace>` | Pulls the exact manifest Helm last actually applied for a release, straight from its own stored state — lets you reconstruct and reapply a specific object (like one `Service`) without re-running the whole chart. | OBS-052 — extracted just the `ingress-nginx-controller` `Service` manifest this way and `kubectl apply`'d it directly to restore the ELB immediately, instead of waiting on a full Helm reinstall. |

### `terraform` — reconciling state, plan, and reality

| Command | Purpose | Real example |
|---|---|---|
| `terraform plan -replace=<address>` | Forces one specific resource to be destroyed and recreated on the next apply, without guessing at `count`/`taint` semantics — the precise tool for "this one thing needs to be rebuilt, nothing else." | OBS-031's recovery — recreated just the `ingress-nginx` Helm release after an unrelated apply had deleted its Service as a side effect. |
| `terraform plan -target=<address>` / `apply -target=<address>` | Plans or applies just one resource, skipping the rest of the graph — used to fix a single missing piece (like an IAM policy) fast, without a full-stack apply. | OBS-069's live recovery — applied just the missing `aws_iam_role_policy.aws_lb_controller`, not a full re-apply. |
| `terraform state rm <address>` / `terraform import <address> <id>` | Removes a resource from state without destroying the real object, or attaches state to a real object Terraform doesn't yet track — the pair used to fix state-vs-reality drift (Terraform pointed at the wrong real resource, or a resource that exists but was never recorded). | TF-003/TF-010 (import a resource state lost track of), OBS-026 (state-surgery to swap Terraform's zone tracking onto the zone the registrar actually delegates to). |
| `terraform force-unlock <lock-id>` | Releases a state lock left behind by an apply that was interrupted mid-run (dropped connection, killed process) without a clean unlock. | TF-019 — the specific recovery step after a network drop mid-`apply`. |

### `docker` / SSH — the monitoring EC2, the one box outside Kubernetes entirely

| Command | Purpose | Real example |
|---|---|---|
| `docker ps` / `docker compose ps` | Confirms which containers are actually up on the monitoring EC2 — the Docker Compose equivalent of `kubectl get pods` for the one part of this stack that isn't in the cluster. | OBS-041 diagnosis path; general first check for OBS-024. |
| `docker compose logs` / `docker logs <container>` | Reads a specific container's logs directly on the box, for exactly the same reason `kubectl logs` is used in-cluster. | OBS-042 — `docker logs kube-state-metrics` showed the repeated `Unauthorized` reflector errors that pointed at the stale-bearer-token root cause. |
| `docker compose up -d` / `docker restart <container>` | Brings the stack back up, or recycles one specific container without touching the rest — used both for manual recovery and as the actual fix mechanism (a scheduled restart) once the root cause was understood. | OBS-042's fix is literally a scheduled `docker restart kube-state-metrics`, not a code change to the container itself. |

### `git` / `gh` — recovering history and CI state

| Command | Purpose | Real example |
|---|---|---|
| `git log --all -p -- <path>` / `git log -p` | Walks a file's full history with diffs, across all branches — used to recover content that was deleted somewhere along the way, not just to read the current version. | OBS-068 — recovered the original two seed books' exact title/desc/price/cover values from a long-deleted ConfigMap's git history. |
| `git show <sha>:<path>` | Prints a file's exact content as of one specific commit, without checking that commit out. | OBS-023 — used to confirm what the manifest *should* have looked like at the commit ArgoCD claimed to be synced to. |
| `git worktree` | Checks out a specific commit into a separate, throwaway directory without disturbing the current branch/working tree — used for the same kind of "what did this look like at commit X" comparison as `git show`, when a full directory (not just one file) needs inspecting. | Same OBS-023 diagnosis, cross-checking `kubectl kustomize` output against a clean checkout of the target commit. |
| `git ls-tree -d <ref> -- <path>` | Confirms whether a directory exists (or ever existed) at a given ref, without checking anything out. | OBS-011 — confirmed `k8s/overlays` genuinely never existed on `main`, ruling out a stale-cache explanation for ArgoCD's `path does not exist` error. |
| `gh run list --branch <branch>` | Lists CI run history and pass/fail status for a specific branch — the fast way to see whether a branch's pipeline has been failing, and since when. | OBS-005 — showed every run on `observability` as `completed failure`, which turned out to be a different, earlier-stage bug masking the one actually being investigated. |
| `gh run rerun` / `gh run rerun <id> --failed` | Re-triggers a specific CI run (or just its failed jobs) without pushing a new commit. | OBS-028 — used, and specifically found to be *insufficient* here: immutable ECR tags meant a rerun of the same commit couldn't get past a partial prior failure — recorded as a real limitation, not just a working fix. |
| `gh api repos/<owner>/<repo>/contents/<path>?ref=<ref>` | Fetches one file's raw content directly from GitHub's API for a specific ref — used to verify a third-party dependency's own internals before trusting a version bump. | OBS-014 — fetched a pinned Action's own `action.yaml` to confirm its *internal* dependency was hash-pinned too, before bumping to that version. |

### Network — `dig`, `whois`, `curl` (isolating DNS from routing from application health)

| Command | Purpose | Real example |
|---|---|---|
| `dig +short <host>` / `dig @8.8.8.8 <host>` | Resolves a hostname directly against a specific public resolver, bypassing local DNS cache — separates "hasn't propagated yet" from "genuinely has no record," which a browser or local `ping` can't distinguish. | OBS-026, OBS-039 — both confirmed a domain returning nothing even against `8.8.8.8`, ruling out a local caching issue. |
| `whois <domain>` | Reads the domain's actual registrar-level nameserver delegation — the layer above Route53 entirely, and the only way to catch a registrar pointing at the wrong hosted zone. | OBS-026, OBS-039 — both traced a "site unreachable" symptom back to the registrar delegating to a zone that no longer existed or was never the right one. |
| `curl` with an explicit `Host:` header, or straight to a load balancer's DNS name | Tests one specific layer of the request path in isolation — bypassing DNS entirely (by hitting the LB's own hostname) to prove whether ingress → service → pod is healthy independent of whether the domain resolves at all. | OBS-039 — `curl` straight to the ELB with a `Host:` header returned a correct response even while the domain itself didn't resolve, proving the app was fine and the bug was purely DNS/registrar. |

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
- **K8S-003:** ingress-nginx had no PodDisruptionBudget — a `kubectl drain` could evict the only ingress pod and drop all external traffic. Fixed via `controller.podDisruptionBudget.minAvailable: 1`. (Superseded 2026-08-14 — `minAvailable: 1` at `replicaCount: 1` was itself the OBS-049-shaped undrainable-pod bug; now `replicaCount: 2` / `maxUnavailable: 1`, see OBS-054.)

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

**Superseded 2026-08-15 — see OBS-055.** The infra was fixed, not the docs: the NLB annotation was added, the LB really is an NLB now, and the "NLB" naming throughout this project's docs — which was wrong when this entry was written — is accurate as of that fix. This entry stays as an accurate historical record of a real bug hunt; don't take its "it's a Classic ELB" claim as current.

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

**Root cause:** the schema+seed SQL (`CREATE DATABASE`/`CREATE TABLE books`/two seed `INSERT`s) had only ever existed in `k8s/base/database/mysql-init-configmap.yaml` — a ConfigMap mounted by the in-cluster MySQL StatefulSet (`mysql-statefulset.yaml`), dead code even at the time (RDS replaced it, confirmed: neither file was ever referenced by `k8s/base/kustomization.yaml`'s `resources:` list). Both files, plus `mysql-service.yaml`, were deleted 2026-08-14 as part of a FinOps/standards cleanup pass — kept here only as historical context for this incident. When the project migrated to RDS, this initialization SQL never got ported over — RDS has been provisioned and empty since. `backend/app.js`'s `/books` route only ever does `SELECT * FROM books`; nothing in the old monolith path ever issued a `CREATE TABLE`. Consistent with OBS-017's finding that no DB connection in this project's history had ever actually succeeded end-to-end before this session — the missing table was simply never reached.

**Fix:** added `k8s/base/database/schema-init-job.yaml`, an ArgoCD PreSync hook Job for the `bookstore` Application, following the exact pattern already proven for `catalog-service` (`k8s/services/catalog-service/base/schema-init-job.yaml`): same `hook-delete-policy: BeforeHookCreation,HookSucceeded` (OBS-015), same pod `securityContext`/container `securityContext` (Semgrep gate), same escaped-backtick heredoc approach for the `` `desc` `` column (OBS-017) — verified locally with the same capture-and-diff heredoc simulation before committing. Idempotent via `WHERE NOT EXISTS (SELECT 1 FROM test.books WHERE title = ...)` rather than catalog's `ON DUPLICATE KEY UPDATE`, since `books.title` has no unique constraint to key off of (unlike catalog's `id`-based migration).

Two supporting fixes needed alongside it:
- Labeled the hook pod `app: backend` — matches `network-policy.yaml`'s existing `backend-policy` `podSelector`, so its already-present egress rule to the RDS CIDR on port 3306 applies without writing a new NetworkPolicy.
- Added the same `argocd.argoproj.io/hook: PreSync` + `sync-wave: "-1"` annotation to `db-secret`'s `ExternalSecret` (`k8s/base/secrets/external-secret.yaml`) that catalog's `admin-db-secret`/`catalog-db-secret` already carry — without it this Job would hit the exact `CreateContainerConfigError` race OBS-013 already found and fixed once for catalog-service.

**Status:** fixed and committed, not yet verified against a real ArgoCD sync as of this entry.

### OBS-021 — `backend-schema-init` never got a pod: `bookstore-quota` rejected it for missing resources

**Symptom:** the Job (from OBS-020) sat `Running 0/1` for 15+ minutes with **zero actual pods** — `kubectl get pods -n bookstore` never showed it at all:
```
Warning  FailedCreate  ...  job-controller  Error creating: pods "backend-schema-init-..." is forbidden: failed quota:
bookstore-quota: must specify limits.cpu for: schema-init; limits.memory for: schema-init;
requests.cpu for: schema-init; requests.memory for: schema-init
```

**Root cause:** `k8s/base/quota.yaml`'s `bookstore-quota` `ResourceQuota` requires every container created in the `bookstore` namespace to declare `requests`/`limits` for both cpu and memory — a Kubernetes-enforced admission rule, not a soft default. `schema-init-job.yaml`'s container never set any (it was modeled directly on catalog-service's version, which has no equivalent quota in the `catalog` namespace and so never hit this). Every pod-create attempt was rejected outright; `backoffLimit` never even got a chance to count against real attempts since none of them became real pods.

**Fix:** added a `resources` block to the container, matching what `backend`'s own Rollout container already uses (`k8s/base/backend/rollout.yaml`): `requests: {cpu: 50m, memory: 64Mi}`, `limits: {cpu: 250m, memory: 128Mi}`.

**Status:** fixed and committed, not yet re-verified against a real sync as of this entry.

### OBS-022 — `catalog-schema-init` races `backend-schema-init` across two independent ArgoCD Applications

**Symptom**, once OBS-021 let `backend-schema-init` actually run:
```
ERROR 1146 (42S02) at line 11: Table 'test.books' doesn't exist
```
still hit by `catalog-schema-init`, even though the Job that creates `test.books` (OBS-020) had, by then, already been fixed and pushed.

**Root cause:** ArgoCD's `sync-wave` ordering only applies to hooks **within a single Application's sync**. `backend-schema-init` (creates `test.books`) lives in the `bookstore` Application; `catalog-schema-init` (migrates *from* `test.books`) lives in the separate `catalog-service` Application. Nothing orders one Application's sync relative to the other's — both were triggered by the same manual `argocd.argoproj.io/refresh=hard` + patched `operation.sync` in this session, and `catalog-service`'s hook simply won the race on that particular sync. This isn't a one-time fluke; it can recur on any future sync where timing happens to favor `catalog-service`.

**Fix:** rather than trying to force cross-Application ordering (no clean mechanism for it short of an App-of-Apps restructure, deliberately not undertaken here), made the migration self-guarding: replaced the bare `INSERT INTO catalog_db.books ... SELECT ... FROM test.books` with a dynamic-SQL block that checks `information_schema.tables` for `test.books` first and no-ops (`SELECT 1`) if it isn't there yet, instead of hard-failing. Idempotent by design (same as the rest of this script) — a sync that skips the migration today will pick it up cleanly on a later sync once `test.books` actually exists, no manual intervention needed. Verified the heredoc/backtick handling locally before committing (same capture-and-diff method as OBS-017); the dynamic SQL itself (`SET`/`IF`/`PREPARE`/`EXECUTE`/`DEALLOCATE`) is standard MySQL 8.0 syntax, reviewed but not executed against a live server (no local MySQL available in this session's environment).

**Status:** fixed and committed, not yet re-verified against a real sync as of this entry.

### OBS-023 — ArgoCD repo-server served a stale (pre-fix) manifest for the schema-init hook across two separate hard-refresh cycles

**Symptom:** after OBS-021's quota fix was committed and pushed, `backend-schema-init` kept getting recreated with `resources: {}` — the exact same quota rejection as before — even though `status.sync.revision` on the `bookstore` Application correctly showed the new commit, and `kubectl kustomize` against that exact commit (verified via `git show <sha>:...` and a throwaway `git worktree`) produced the correct manifest with `resources` populated. This persisted across two independent `argocd.argoproj.io/refresh=hard` + forced-resync cycles.

**Root cause (confirmed, not just suspected):** compared `kubectl apply --dry-run=server` of the exact same manifest via plain `kubectl` against what ArgoCD actually submitted (visible in the Job's `.metadata.managedFields` — the ArgoCD field manager's entry had no `f:resources` key at all, meaning it never sent that field in its server-side apply request). Plain `kubectl apply -f` of the identical YAML created the Job correctly, with `resources` populated, on the first try — ruling out a cluster-side admission webhook or the YAML itself. This isolates the bug to ArgoCD's repo-server: it served an internally-cached manifest generation for this hook resource that predated the fix, and `refresh=hard` did not reliably invalidate that cache for this specific resource across two attempts.

**Workaround used to unblock:** deleted the stuck Job, stripped its `argocd.argoproj.io/hook-finalizer` (same technique as OBS-015) so the delete actually completed, then applied the correct manifest directly with `kubectl apply -f` (bypassing ArgoCD for this one hook run only). The Job completed successfully; ArgoCD's `BeforeHookCreation` policy cleaned it up on the next reconcile like any other successful hook run, so no orphaned state was left behind.

**Status:** unblocked for this run via the workaround above. The underlying repo-server staleness is NOT fixed — it's an ArgoCD-side caching behavior, not something in this repo's manifests. If this recurs, try `kubectl rollout restart deployment argocd-repo-server -n argocd` (not yet tested) before reaching for the manual-apply workaround again. Worth a real root-cause dig if it keeps happening (single repo-server replica, so not a stale-replica-behind-a-LB issue — more likely a manifest-generation cache TTL or key that doesn't fully bust on `refresh=hard` for `PreSync` hook resources specifically).

### OBS-024 — Backend Rollout's canary analysis aborts: monitoring EC2's whole stack (Prometheus/Grafana/Alertmanager) unreachable

**Symptom**, once OBS-020/021/023 got a real, working backend pod running for the first time:
```
Metric "error-rate" assessed Error due to consecutiveErrors (5) > consecutiveErrorLimit (4):
"Error Message: Post \"http://13.57.1.221:9090/api/v1/query\": dial tcp 13.57.1.221:9090: connect: connection refused"
```
`Rollout aborted update to revision 2` — the new (working, prom-client-fixed) pod came up and passed its own readiness probe, but the canary's background `AnalysisRun` couldn't reach Prometheus at all, so Argo Rollouts aborted the promotion. `Stable RS` stayed pinned to the OLD, crashlooping ReplicaSet.

**Root cause:** confirmed live — `curl` to all three monitoring ports (`9090` Prometheus, `3000` Grafana, `9093` Alertmanager) at `13.57.1.221` returned connection failures from **outside** the cluster too (not a cluster-networking/SecurityGroup issue — the SG explicitly allows all three from `0.0.0.0/0`, verified via `aws ec2 describe-security-groups`). The EC2 instance itself (`i-044d178aab2c55cd2`, `bookstore-monitoring`) is `running` per `aws ec2 describe-instances`, so this looks like the Docker Compose monitoring stack on the box has stopped or crashed, not an instance-level or network-level failure. SSM Session Manager isn't registered for this instance (`aws ssm describe-instance-information` returned empty), so remote diagnosis needs actual SSH access — `make monitoring-status` / `make monitoring-logs` (both require SSH, per `DEPLOYMENT.md`).

**Important — this is NOT a production outage.** Kubernetes Services only route to pods that pass readiness; the crashlooping old pod (`0/1 Ready`) was never actually receiving traffic despite being nominally "Stable" in the Rollout's bookkeeping. Verified directly: `curl` through `svc/backend-service` returned real data from the new, healthy pod. Real user-facing impact of this bug is zero right now — it only blocks the Rollout's own promotion bookkeeping (and, by extension, any *future* backend deploy's canary analysis, until monitoring is back).

**Status:** NOT fixed — needs SSH access to `bookstore-monitoring` to diagnose (`make monitoring-status`, `make monitoring-logs`, or `docker compose ps`/`docker compose logs` directly on the box) and restart whatever's down. Once monitoring is back, retry the aborted rollout (`kubectl argo rollouts retry rollout backend -n bookstore` if the plugin's installed, or `kubectl annotate rollout backend -n bookstore kubectl.kubernetes.io/restartedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite` otherwise) — no point retrying before then, since the same abort will just recur.

### OBS-025 — the site's actual hostnames never had Route53 records; only the bare apex ever did

**Symptom:** asked to verify the site is reachable by browser. `bookstore.b17facebook.xyz` and `api.bookstore.b17facebook.xyz` — the exact hosts `k8s/base/ingress/ingress.yaml`'s `Ingress` rules match — had **zero** Route53 records, in either hosted zone this project has ever used. The apex (`b17facebook.xyz` alone) has had a correct ALIAS record since early in this session, but nothing in the Ingress config ever serves content at the bare apex — nginx's default backend returns 404 for any Host header that doesn't match a configured rule, apex included.

**Root cause:** `modules/route53/main.tf`'s `primary`/`primary_cf`/`secondary` records all target `var.domain` (the apex) only — nobody ever added records for the two subdomains the app is actually served on. Consistent with this session's running theme (RDS never had a schema, the image never had `prom-client`, now DNS never pointed at the real hostnames) — pieces of this stack that were configured once and never verified against real, end-to-end traffic.

**Fix:** added `aws_route53_record.frontend` (`bookstore.<domain>`) and `aws_route53_record.api` (`api.bookstore.<domain>`) to `modules/route53/main.tf` — same ALIAS-to-ingress-LB pattern as `primary`, no failover/health-check (that complexity is apex-only in this design). Not gated on `var.primary_alb_dns != ""` for the same plan-time-unknown-value reason `primary` isn't (OBS-008).

**Status:** fixed and committed. Needs a real `terraform apply` to create the actual records — not yet run as of this entry. Also blocked in practice by OBS-026 (GoDaddy isn't even delegated to the zone these records get created in) until that's resolved.

### OBS-026 — GoDaddy's registrar delegation points at a different, orphaned Route53 zone than the one Terraform manages

**Symptom:** asked to make the site reachable, discovered neither `b17facebook.xyz` nor its subdomains resolve at all — not a propagation delay, confirmed via `dig @8.8.8.8` (bypasses local resolver cache) and `whois`.

**Root cause:** `whois b17facebook.xyz` shows GoDaddy's registered nameservers as `ns-1446.awsdns-52.org` / `ns-941.awsdns-53.net` / `ns-243.awsdns-30.com` / `ns-1567.awsdns-03.co.uk`. `aws route53 list-hosted-zones-by-name --dns-name b17facebook.xyz` shows **two** hosted zones for this domain in the account: `Z05284462VHV14S4GNFNS` (Terraform-managed, `CallerReference: terraform-...`, the one OBS-018's `prevent_destroy` protects, has the correct apex ALIAS record) and `Z09020593QE7ZCUI17J3` (not Terraform-managed, `CallerReference` a random UUID — evidently created manually at some earlier point in this project's history, before this session). GoDaddy's registered nameservers match the **second** zone, not the Terraform-managed one. That zone contains only its own NS/SOA records and one leftover CNAME from a stale, unrelated ACM DNS-validation request — no ALIAS record, no subdomain records, nothing pointing at the ingress LB. OBS-018 protected the wrong zone from the registrar's point of view: the zone it protects isn't the one anything on the public internet actually reaches.

**Decision:** given the choice between (a) updating GoDaddy's nameservers to point at the Terraform-managed zone, or (b) importing the zone GoDaddy already points at into Terraform state and dropping the orphaned one, chose **(b)** — avoids another manual GoDaddy trip, matches the earlier stated preference (OBS-018) to leave the registrar alone for now.

**Fix (state surgery — run manually, not automated):**
```bash
terraform state rm module.route53.aws_route53_zone.public
terraform import module.route53.aws_route53_zone.public Z09020593QE7ZCUI17J3
terraform plan   # review: existing record resources (primary, primary_cf, the two
                  # new OBS-025 subdomain records) will show as replacements —
                  # expected, they're moving from the old zone_id to this one
terraform apply
```
After a successful apply, the orphaned zone (`Z05284462VHV14S4GNFNS`) is no longer Terraform-tracked and can be deleted by hand (`aws route53 delete-hosted-zone --id Z05284462VHV14S4GNFNS`, after confirming it's empty of anything still needed) to avoid confusion and the small monthly per-zone charge. `modules/route53/main.tf`'s `aws_route53_zone.public` resource block itself needs no code change — this is purely a state-identity swap onto an AWS object that already exists.

**Status:** not yet run as of this entry — needs the user to run the state surgery above directly (this session's established pattern never runs `terraform apply`, and state `rm`/`import` carry the same or higher risk).

### OBS-027 — `make monitoring-status`/`monitoring-logs` have never been able to connect: no port 22 rule, no SSH key at all

**Symptom:** trying to diagnose OBS-024 (monitoring stack unreachable) by SSHing in:
```
ssh: connect to host 13.57.1.221 port 22: Operation timed out
```
A timeout, not an auth failure — the connection never got a response at all.

**Root cause, two separate gaps in `modules/monitoring-ec2/main.tf`:** (1) `aws_security_group.monitoring` had ingress rules for 3000/9090/9093/3100 only — port 22 was never in the security group at all, confirmed via `aws ec2 describe-security-groups ... IpPermissions[?ToPort==22]` returning `[]`. (2) even with the SG fixed, `aws_instance.monitoring` never set `key_name` — Ubuntu's cloud-init only seeds `~/.ssh/authorized_keys` from an EC2 key pair supplied at launch (or explicit user-data, which this project's `user-data.sh.tftpl` also doesn't do), so SSH had no way to authenticate. The Makefile's own comment ("requires SSH key in agent") implies the original intent was working key-based SSH — it just never got wired up on the Terraform side.

**Fix:** added a port 22 ingress rule (same `var.admin_cidr_blocks` scoping as the other UI ports — narrow it in production per that variable's own description). Added `tls_private_key.monitoring_ssh` + `aws_key_pair.monitoring`, wired `key_name` into the instance, and a new sensitive output (`ssh_private_key_pem` on the module, `monitoring_ssh_private_key` at root) — auto-generated rather than requiring the user to bring their own, matching this project's existing automate-everything posture. Added `Makefile`'s `monitoring-key` target (`terraform output -raw monitoring_ssh_private_key > .monitoring-ssh-key.pem && chmod 400 ...`) as a prerequisite of both `monitoring-status`/`monitoring-logs`, which now pass `-i $(MONITORING_KEY)`. `*.pem` was already gitignored.

**Real consequence, flagged before applying, not hidden:** `aws_instance`'s `key_name` is a ForceNew attribute — verified via a real `terraform plan` that this change **destroys and recreates** the monitoring EC2 instance (`aws_instance.monitoring must be replaced`, `aws_eip_association.monitoring must be replaced` alongside it). The EIP itself is untouched, so the public IP (and therefore every `*_url` output, and DNS if anything pointed at it) stays identical — only the instance/root-volume identity changes, then gets re-associated. Since OBS-024 already found the whole monitoring stack unreachable (nothing currently being collected), losing whatever was on the old root volume is not a real loss right now — and the replacement's fresh `user-data.sh.tftpl` run may incidentally resolve OBS-024 too, though that's not confirmed until it's actually applied.

**Status:** fixed and committed, not yet applied as of this entry.

### OBS-028 — `gh run rerun --failed` can't recover from a partial `build-and-push` failure: immutable ECR tags reject the retry

**Symptom**, hit deploying order-service/notification-service before their ECR repos existed yet (Terraform hadn't been applied): the `build-and-push` job failed at `Push notification-service image` with `name unknown: The repository with name 'bookstore-notification-service' does not exist in the registry` — expected, since `terraform apply` hadn't run yet. But `backend`, `catalog-service`, and `user-service`'s pushes, earlier in the same job, had already succeeded under image tag `4cf13de7` before the job aborted on the missing repo. After running `terraform apply` to create the missing repos, re-running just the failed job (`gh run rerun <id> --failed`) failed again — this time on the very first push, `backend`:
```
tag invalid: The image tag '4cf13de7' already exists in the 'bookstore-backend' repository
and cannot be overwritten because the tag is immutable.
```

**Root cause:** `modules/ecr/main.tf` sets `image_tag_mutability = "IMMUTABLE"` on every repo (deliberate — prevents a compromised or buggy CI run from silently overwriting a previously-deployed image under the same tag, a real supply-chain protection). The image tag is derived from the git SHA (`${GITHUB_SHA::8}` in `ci-cd.yml`'s "Derive image tag" step), so `gh run rerun` — which replays the exact same job against the exact same commit — always regenerates the exact same tag. That's fine when the whole job failed before any push succeeded, but this job's `build-and-push` steps are sequential per-service, not atomic — a partial failure (some services' images already pushed, later ones not) leaves the run in a state no rerun of the *same commit* can ever get past, since the tag collision on the already-pushed services is permanent and by design un-overridable.

**Fix:** there isn't one at the workflow level worth making — this is the immutable-tag protection working as intended, just surfaced in an unfamiliar way (a *partial* failure, not a full one). The actual fix is operational: push a new commit (even a docs-only one, as this entry itself is) to get a new SHA-derived tag, which then pushes cleanly for every service, including the ones that "succeeded" under the stale tag — they simply get re-pushed under the new tag too, harmlessly.

**Status:** not a bug to fix in code. Recorded here so a future partial `build-and-push` failure isn't mistaken for something `gh run rerun` should be able to fix — it can't, once any image in the same run has already landed under an immutable tag. Push a new commit instead.

### OBS-029 — `terraform destroy` real-run findings: one orphaned pre-Terraform record, a false-alarm timeout, and confirmed post-destroy leftovers outside state

**Symptom, run 1:** `terraform destroy` failed on the Route53 public zone with `HostedZoneNotEmpty`, even after `prevent_destroy` was removed (see OBS-018). `aws route53 list-resource-record-sets` on the zone showed one `CNAME` record that was never in Terraform state — created directly via the console before this project's Route53 was ever managed by Terraform, so `destroy` had no way to know about it or remove it.

**Fix:** deleted the orphaned `CNAME` record directly via `aws route53 change-resource-record-sets` (one-off, not a code change — Terraform can't clean up what it never created). Re-running `terraform destroy` after that completed the zone deletion.

**Symptom, run 1 continued:** a `helm_release` resource appeared to time out during the same destroy. Turned out to be a false alarm — the underlying Helm uninstall had actually completed; the resource was just slow to report state back to Terraform. No fix needed, just don't assume every destroy-time timeout is a real stuck resource — check the underlying AWS/K8s state before treating it as an incident.

**Post-destroy audit (2026-08-05):** ran a full AWS-account sweep across `us-west-1`/`us-west-2` afterward specifically to confirm no leftover billable resources remained. EKS, EC2, RDS, NAT gateways, Classic ELB/NLB/ALB, Elastic IPs, Secrets Manager, CloudFront, and VPC endpoints were all confirmed clean. Three categories were **not** clean — see [`FUTURE_IMPROVEMENTS.md`](FUTURE_IMPROVEMENTS.md) gap #13 for the underlying cause and fix direction:
- 10 orphaned EBS volumes (K8s CSI-driver-created `PersistentVolumeClaim` volumes, never in Terraform state)
- 6 ECR repos in `us-west-2` still holding pushed images (no `force_delete` on the `ecr` module)
- An empty but undeleted VPC (`MAIN-3-TIER-VPC`) with one orphaned `k8s-elb-...` security group left by the in-tree cloud provider — blocks the VPC itself from going away even though it has no subnets/IGW/instances left

None of this blocked the destroy from completing; it's cost hygiene, not correctness. **Status:** found, not yet deleted — flagged to the user for confirmation before any manual cleanup, since none of it is Terraform-managed and deletion is one-way.

### OBS-030 — On a genuinely fresh cluster, every `ExternalSecret` fails its first sync: `ClusterSecretStore` has no hook annotation, so it's always created *after* every `PreSync` hook, not before

**Symptom**, hit re-applying from scratch after the OBS-029 destroy: `terraform apply` succeeded, but every ArgoCD Application (`bookstore` + all 5 microservices) failed to sync, retried 5 times, then gave up (`operationState.phase: Failed`). Every `ExternalSecret` across every namespace showed the identical error:
```
could not get secret data from provider
```
and the ESO controller's own logs were explicit:
```
could not get ClusterSecretStore "aws-secretsmanager", ClusterSecretStore.external-secrets.io "aws-secretsmanager" not found
```
Applying `k8s/base/secrets/external-secret.yaml` directly with `kubectl apply -f` worked instantly and every time — so the manifest itself was never wrong.

**Root cause:** `k8s/base/secrets/external-secret.yaml`'s `db-secret` `ExternalSecret` (and every microservice's own `ExternalSecret`) is annotated `argocd.argoproj.io/hook: PreSync`, `sync-wave: "-1"` — this was done deliberately (OBS-013) so it's guaranteed to exist before the schema-init Jobs that need it. But the `ClusterSecretStore` it depends on, `aws-secretsmanager`, had **no hook annotation at all** — a plain resource, applied during ArgoCD's normal Sync phase. ArgoCD always runs every `PreSync` hook to completion *before* the Sync phase starts, for every application, on every sync — this isn't a race that sometimes loses, it's a guaranteed ordering violation every single time the store doesn't already exist from a previous run. It only ever "worked" before because the store was already sitting in the cluster from an earlier apply, never actually created by a from-scratch `PreSync`-first bootstrap until this destroy/recreate cycle exposed it. Once ArgoCD retries were exhausted, the failed operation's own hook cleanup also removed the just-created `ExternalSecret` between attempts, so even a lucky sync couldn't have shortcut the ordering problem.

**Fix:** gave `ClusterSecretStore` its own `PreSync` hook annotation at an earlier wave than every `ExternalSecret` that depends on it (`sync-wave: "-2"`, vs. the existing `-1`), so ArgoCD now creates it strictly before any `ExternalSecret` tries to resolve against it, on every sync, not just ones where it happened to already exist:
```yaml
metadata:
  name: aws-secretsmanager
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/sync-wave: "-2"
```

**Immediate unblock used while diagnosing:** manually created the `ClusterSecretStore` via `kubectl apply -f k8s/base/secrets/external-secret.yaml`, then applied `k8s/overlays/prod` directly via `kubectl apply -k` to get the monolith live without waiting on ArgoCD's flaky hook-retry loop — ArgoCD's `selfHeal` reconciles cleanly against already-live resources on its next pass rather than fighting them. The microservice `Application`s recovered on their own once the store existed and a fresh sync was triggered (`kubectl -n argocd patch application <name> --type merge -p '{"operation":{"sync":{"syncStrategy":{"hook":{}}}}}'`).

**Status:** fixed in `k8s/base/secrets/external-secret.yaml`, committed. Not yet proven on a second from-scratch destroy/apply cycle — the manual `kubectl apply` workaround above got this specific cluster unblocked before the git fix was pushed and picked up by ArgoCD's poll.

### OBS-031 — Real production downtime: a `terraform apply` for an unrelated node-count bump deleted the live ingress-nginx `LoadBalancer` Service

**Symptom:** ran `terraform apply` purely to bump `node_desired_size`/`node_max_size` from 2 to 3 (see OBS-030's node-capacity trigger). The plan showed 2 unrelated null_resources being replaced — `null_resource.wait_for_alb_hostname` (expected every apply, see its own comment) and, unexpectedly, `module.eks_addons.null_resource.delete_ingress_nginx_lb`. That second resource's **only** provisioner is `when = destroy` — meant purely for `terraform destroy`-time cleanup (releasing the NLB before VPC teardown, TF-017) — but replacement (destroy-then-create of the null_resource itself) is enough to fire a `when = destroy` provisioner too. It ran for real:
```
kubectl delete svc ingress-nginx-controller -n ingress-nginx --wait --timeout=120s --ignore-not-found
```
against the live cluster, deleting the actual production ingress LoadBalancer. The site was unreachable externally until recovered.

**Root cause, only partially pinned down:** `delete_ingress_nginx_lb`'s `triggers` (`cluster_name`, `region`) are static values (`var.cluster_name`/`data.aws_region.current.name`) that shouldn't change between applies, and `aws_eks_cluster.this.name` (the source of `cluster_name`) has no dependency on the node group being resized — so the specific mechanism that caused Terraform to decide this resource needed replacing on *that* apply is still unconfirmed. A follow-up `terraform plan -replace=...` for an unrelated fix (recreating the ingress-nginx Helm release) did **not** show `delete_ingress_nginx_lb` as needing replacement, so whatever caused it appears to have been tied to that specific apply, not a guaranteed every-time repro. Needs closer investigation before the next node-group or eks-module change — **always read the full plan output for any `null_resource` in `modules/eks-addons/` before applying**, not just the resource you meant to change.

**Recovery:**
```bash
terraform plan -replace="module.eks_addons.helm_release.ingress_nginx" -out=fix-ingress.tfplan
# verify delete_ingress_nginx_lb does NOT appear in the plan before applying
terraform apply "fix-ingress.tfplan"
```
Reinstalls the ingress-nginx chart → new Service → new NLB → `wait_for_alb_hostname` (tainted from the earlier failed apply, always replaces anyway) picks up the new hostname → `api`/`frontend`/`primary` Route53 alias records update automatically via `data.kubernetes_service.ingress_nginx`.

**Status:** recovered. Root cause of why `delete_ingress_nginx_lb` replaced on the node-scaling apply specifically is not fully explained — treat any `terraform plan` touching `modules/eks-addons` or `module.eks` as a reason to scan the full resource list for this null_resource before applying, until this is properly root-caused.

### OBS-032 — Every canary rollout aborts after a destroy/recreate: the Argo Rollouts `AnalysisTemplate` hardcodes the monitoring EC2's Elastic IP as a literal

**Symptom:** after OBS-031's recovery, the `backend` Rollout's canary (revision 2, the freshly-pushed `9228e980` image) aborted:
```
Rollout aborted update to revision 2: Background analysis phase error/failed: Metric "error-rate" assessed
Error due to consecutiveErrors (5) > consecutiveErrorLimit (4): "Error Message: Post
\"http://13.57.1.221:9090/api/v1/query\": dial tcp 13.57.1.221:9090: i/o timeout"
```
The old ReplicaSet's pod was stuck `ImagePullBackOff` (referencing a tag deleted along with the destroyed ECR repos), and the Rollout stayed `Degraded`.

**Root cause:** `k8s/base/monitoring/analysis-template.yaml`'s `provider.prometheus.address` is a hardcoded literal IP (`http://13.57.1.221:9090`) — the monitoring EC2's `aws_eip.monitoring` **at the time this file was last edited**. A full `terraform destroy` tears down the `aws_eip` resource itself (not just the instance — OBS-027 established the EIP survives an *instance* replacement, but that's different from the whole resource being destroyed), so the very next `apply` allocates a **brand-new** Elastic IP address (`18.144.141.146` this cycle). Nothing re-templates this manifest from the new `terraform output prometheus_url` — it silently goes stale, and every canary analysis after a destroy/recreate fails with a connection timeout until someone notices and hand-edits the IP.

**Fix applied this cycle:** updated the literal to `http://18.144.141.146:9090`, applied directly (`kubectl apply -f`), then forced the Rollout to attempt a fresh revision (`kubectl patch rollout backend -n bookstore --type merge -p '{"spec":{"template":{"metadata":{"annotations":{"kubectl.kubernetes.io/restartedAt":"<timestamp>"}}}}}'` — a template annotation bump, since `restartAt` alone only restarts existing pods in place and doesn't create a new revision, so it doesn't re-run analysis against a fixed target).

**Real fix, not yet done:** this manifest should read the monitoring EC2's IP dynamically instead of a checked-in literal — e.g., templated via `kustomize` from a `ConfigMap` populated by Terraform (matching the pattern other services already use for config), or the schema-init-job pattern of reading from an `ExternalSecret`. Whatever the mechanism, "hardcoded literal IP in a git-committed K8s manifest, sourced from a resource that gets a new value on every full recreate" is exactly the same class of bug as the Route53/ECR/EBS orphan findings in OBS-029 — anything that assumes AWS resource identity is stable across a destroy/recreate cycle on this project will eventually be wrong.

**Status:** live cluster fixed and unblocked (not yet committed to git as of this entry — the file still needs the literal-IP problem actually solved, not just patched to a new literal). See `docs/FUTURE_IMPROVEMENTS.md` for the tracked gap.

### OBS-033 — The monitoring EC2's entire Docker Compose stack never actually started: `docker-compose-plugin` isn't in Ubuntu's default apt repos

**Symptom:** `make monitoring-status` returned `bash: docker: command not found`. `/var/log/monitoring-init.log` showed the script died at its very first real step:
```
E: Unable to locate package docker-compose-plugin
```
Nothing after that line in `user-data.sh.tftpl` ever ran — no kubectl install, no Prometheus/Grafana/Loki/Alertmanager config, no `docker compose up`. The monitoring stack had likely never been running on this project, on any prior cluster lifetime — this was simply the first time anyone actually SSHed in and checked (OBS-027 fixed SSH *access* but nobody had verified what was on the other end of it until now).

**Root cause:** `docker-compose-plugin` is a Docker-official package, not shipped in Ubuntu jammy's default apt repos — only `download.docker.com`'s own repo has it. The script's original single `apt-get install -y docker.io docker-compose-plugin awscli jq curl` line failed entirely (apt-get aborts the whole command if any listed package can't be located), and `set -euo pipefail` at the top of the script meant that one failure killed everything downstream.

**A second bug surfaced immediately after fixing the first:** adding Docker's official apt repo and installing `docker-ce`/`docker-ce-cli`/`containerd.io`/`docker-compose-plugin` properly works — but the ORIGINAL script also still listed Ubuntu's own `docker.io` package, which conflicts with `containerd.io` (Ubuntu's `docker.io` pulls in `containerd`, which conflicts with Docker Inc's `containerd.io`). Fixed by dropping `docker.io` entirely and installing only the Docker-official set.

**A third bug, found once Compose actually started:** `kube-state-metrics` crash-looped with `permission denied` reading `/root/.kube/config`. `/root` itself is `0700` on Ubuntu — the container's non-root user can't traverse into it no matter what's mounted inside or that file's own permissions. Fixed by writing the kubeconfig to `/opt/monitoring/kube/config` instead and mounting `user: "0:0"` on that one container.

**A fourth bug, found right after that:** with the permission issue fixed, `kube-state-metrics` failed with `exec: executable aws not found` — the image has no AWS CLI, so `aws eks update-kubeconfig`'s exec-based auth (`aws eks get-token`) can never work from inside this specific container, regardless of file permissions. Fixed by switching to a static bearer token instead: a `refresh-kube-token.sh` script (run once at boot, then via cron every 10 minutes, since EKS tokens are short-lived) calls `aws eks get-token` **on the host** (where the CLI does exist) and writes a plain `token:`-auth kubeconfig — no exec plugin needed inside the container at all. Same pattern already used for the Prometheus node-exporter target list (`update-prom-targets.sh`, refreshed every 5 min via cron) — this project already had the right pattern for "value that goes stale, refresh it on a timer," it just hadn't been applied here yet.

**Fix applied:** all four fixed live via SSH on the running instance (`make monitoring-status`/`docker ps` confirmed all 5 containers `Up`, Grafana/Prometheus/Alertmanager all returning `200` externally), and all four fixed in `modules/monitoring-ec2/user-data.sh.tftpl` so a future fresh `terraform apply` doesn't need any of this manual surgery again. `kube-state-metrics` reaching `Up` at the Docker level here was necessary but not sufficient — see OBS-034 immediately below for the fifth bug that kept it from actually working even once it stopped crash-looping.

**Status:** fixed live and in git. Loki intentionally returns nothing when checked from outside the VPC — its security group scopes it to the VPC CIDR only (Fluent Bit push traffic), Grafana reaches it over the internal Docker network, this is by design, not a bug.

### OBS-034 — `kube-state-metrics` stopped crash-looping but still couldn't reach the EKS API: the cluster's security group never allowed the monitoring EC2 in

**Symptom:** after fixing OBS-033's four bugs, `kube-state-metrics`'s container stayed `Up` (no more restart loop), but its logs showed a *new*, consistent failure every ~30s:
```
failed to create client: error while trying to communicate with apiserver:
Get "https://<cluster-id>.sk1.us-west-1.eks.amazonaws.com/version": dial tcp <private-ip>:443: i/o timeout
```
A different private IP each time — the EKS control plane's several per-AZ ENIs — all timing out, never refused, the classic signature of a security-group drop rather than "nothing listening."

**Root cause:** `modules/monitoring-ec2/main.tf` already had a rule allowing the monitoring EC2 to *reach out to* the EKS-managed nodes on port 9100 (node-exporter scraping), but nothing in the other direction — no rule anywhere authorized the monitoring EC2's security group to reach the EKS **cluster** security group on port 443 at all. Confirmed directly: `aws ec2 describe-security-groups` on the cluster SG (`module.eks.cluster_security_group_id`) showed inbound only from itself and the node group's SG — the monitoring EC2's SG was never in that list, on any port relevant to the API server. Given this project has been through several destroy/recreate cycles this session alone, this had apparently never worked, ever — nobody had checked until tonight's `make monitoring-status` prompted actually looking.

**Fix:** added a new `aws_security_group_rule.monitoring_scrape_eks_api` in `modules/monitoring-ec2/main.tf`, the same shape as the existing node-exporter rule, allowing the monitoring EC2's SG inbound on 443 to the cluster SG. Applied live via `aws ec2 authorize-security-group-ingress` first to unblock immediately (purely additive, no existing traffic affected), then committed to git.

**A sixth, minor gap found once the network path worked:** `kube-state-metrics` could now authenticate, but logged `forbidden` on a handful of cluster-scoped resource types (`MutatingWebhookConfiguration`, `VolumeAttachment`, `Lease`, `PersistentVolume`, `Node`) — `AmazonEKSViewPolicy` (the access policy already correctly associated via `module.monitoring_ec2.aws_eks_access_policy_association.monitoring_view`) doesn't cover quite everything kube-state-metrics wants by default. Prometheus reports the target as `up` regardless — the core pod/deployment/service/namespace metrics that matter for the existing Grafana dashboards all work; only a few niche metric families are incomplete. Not chased further tonight; a tighter or additional access policy would be the real fix if those specific metrics turn out to matter.

**Status:** fixed live and in git. `kube-state-metrics` confirmed reporting `up` in Prometheus's own target list.

### OBS-035 — `git push` rejected mid-session: CI's own auto-commits diverge a long-running local branch from origin

**Symptom:** after a long session of local commits on `observability` (16 tasks' worth, building the frontend), a plain `git push` failed:
```
! [rejected]        observability -> observability (non-fast-forward)
error: failed to push some refs to '...'
hint: Updates were rejected because the tip of your current branch is behind its remote counterpart.
```

**Root cause:** this project's CI `deploy` job commits directly back to the branch it just built from — `kustomize edit set image` + `git commit` + `git push`, on every successful build (see `docs/CICD.md`). Earlier in the same session, a prior push had triggered exactly one such CI auto-commit (`chore: bump image tags to <sha>`) on `origin/observability`. All subsequent work that session continued locally on top of the commit *before* that auto-commit, since nothing ever pulled it down — by the time of this push, local and remote had diverged by exactly one commit each at the same point in history (`git merge-base` confirmed a common ancestor with local 24 commits ahead on one side and the single CI commit on the other).

**Fix:** confirmed the divergent remote commit only touched `kustomization.yaml` image-tag fields (mechanical, CI-only files no local commit had touched), then:
```bash
git fetch origin observability
git pull --rebase origin observability   # clean, zero conflicts given the above
# re-run the full test suite + build to confirm the replay didn't break anything
git push
```
A rebase was safe here specifically because the diverging commits were purely local and unpushed (never shared with anyone else) — this is the ordinary, expected case for rebase, not the risky "rewriting published history" kind.

**Status:** resolved for this session. **Systemic risk, not fixed:** any long local session on a branch this CI actively pushes to will hit this again. Worth remembering to `git fetch`/`git pull --rebase` before a push if it's been a while since the last one, especially right after telling the user to approve a deploy gate (that approval is exactly when CI's auto-commit lands).

### OBS-036 — `terraform destroy` failed on `helm_release.external_secrets`: uninstall hung on a finalizer deadlock

**Symptom:** a full `terraform destroy -auto-approve` got 106 resources in, then failed:
```
Error: uninstallation completed with 1 error(s): context deadline exceeded
```
after ~10.5 minutes stuck on `module.eks_addons.helm_release.external_secrets: Still destroying...`. `terraform state list` afterward still showed the EKS cluster, node group, VPC, and the `external_secrets` helm release itself — destroy had stopped partway through.

**Root cause:** every `ExternalSecret` custom resource across `bookstore`/`catalog`/`order`/`user` namespaces carries an `externalsecrets.external-secrets.io/externalsecret-cleanup` finalizer, normally removed by the ESO controller on delete. Helm's uninstall tears down the ESO deployment (and, per its resource policy, keeps the CRDs) — but nothing guarantees the controller pods survive long enough to process every `ExternalSecret` delete first. Once the controller was gone, those objects sat forever with the finalizer still attached, which in turn kept their namespaces stuck in `Terminating` (`kubectl get ns` showed `bookstore`/`catalog`/`order`/`user` all `Terminating` with zero actual resources left in them) — and Helm's uninstall waits on exactly that.

**Fix applied live:** for each stuck namespace, strip the finalizer directly so Kubernetes can finish deleting the (already-empty) object:
```bash
kubectl patch externalsecret <name> -n <ns> --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]'
```
All 4 namespaces cleared within seconds of patching. Re-running `terraform destroy -auto-approve` then completed the remaining 22 resources (EKS, VPC, IAM) with zero errors.

**Status:** worked around live, not yet fixed in Terraform. A durable fix would be ordering the ESO helm release's destroy *after* something that force-deletes/finalizer-strips any remaining `ExternalSecret`/`ClusterSecretStore` objects — e.g. a `null_resource` destroy-time provisioner running the same `kubectl patch` loop, gated on `depends_on` so it always runs before the helm uninstall. Not yet implemented; this will recur on every future full destroy until it is.

### OBS-037 — fresh-cluster ArgoCD sync failed on `ExternalSecret` PreSync hooks even with the OBS-030 ordering fix in place

**Symptom:** immediately after a clean `terraform apply` on a brand-new cluster, 5 of 6 ArgoCD Applications (`bookstore`, `catalog-service`, `notification-service`, `order-service`, `user-service`) sat `OutOfSync`/`Healthy` (health "Healthy" here just meant "nothing deployed yet", not actually healthy) while `api-gateway` alone synced. `kubectl describe application catalog-service -n argocd` showed:
```
phase: Failed
message: one or more synchronization tasks completed unsuccessfully (retried 5 times)
hookPhase: Failed  (ExternalSecret admin-db-secret)
message: could not get secret data from provider
```
and the `ExternalSecret` objects Argo *did* manage to create during the failed attempt were gone again afterward (`kubectl get externalsecrets -A` showed only 2 objects cluster-wide, not the expected 9+).

**Root cause:** OBS-030's `ClusterSecretStore` PreSync/wave-(-2) hook fix is real and does make the store apply before any `ExternalSecret`, but it doesn't guarantee the **ESO controller pods themselves** are ready to serve requests by the time ArgoCD's PreSync hook executes — IRSA/OIDC trust and the AWS SDK client inside the ESO pod both take a few seconds to warm up after the pod goes `Running`. ArgoCD's hook retry budget (5 attempts, exponential backoff, capped ~3min total per the `retry.backoff.maxDuration` in the sync operation) was exhausted before ESO finished warming up, and the sync `Operation` moved to a terminal `Failed` phase — which ArgoCD does not automatically retry; it just waits for the next 3-minute auto-sync poll, which itself doesn't retry a `Failed` operation, only a genuinely `OutOfSync` one.

**Fix applied live:** confirmed via `kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets` that ESO was in fact healthy and successfully reconciling secrets by this point, then manually re-triggered each stuck Application:
```bash
kubectl patch application <name> -n argocd --type=merge \
  -p '{"operation":{"sync":{"revision":"HEAD","prune":true},"initiatedBy":{"username":"manual"}}}'
```
All 5 synced successfully on the retry.

**Status:** worked around live, not fixed durably. A real fix needs either an EKS-Auto-mode-style readiness gate before ArgoCD starts syncing anything dependent on ESO (e.g. a `PreSync` hook Job that polls the ESO deployment's `Available` condition before any `ExternalSecret` is applied), or a longer PreSync hook retry budget so the existing 3-minute auto-poll has a chance to succeed on its own without manual intervention. Related to, but distinct from, OBS-030 — that fix addressed *ordering*, this gap is about *readiness*.

### OBS-038 — full destroy wipes all 7 ECR repos, so every pod ImagePullBackOff's immediately after apply until CI rebuilds

**Symptom:** right after `terraform apply` finished cleanly and ArgoCD synced (see OBS-037), every single application pod across `bookstore`/`gateway`/`catalog`/`user`/`order`/`notification` came up `ImagePullBackOff`/`ErrImagePull`.

**Root cause:** not a bug — `terraform destroy` genuinely deletes all 7 `aws_ecr_repository` resources along with everything else, so a fresh `terraform apply` recreates them empty. The Kubernetes manifests in git still reference whatever image tag was last deployed (e.g. `bookstore-api-gateway:1bf75186`), which no longer exists in the newly-empty repo. Nothing in `terraform apply` builds or pushes application images — that's entirely CI's job, and CI only runs on a `git push`.

**Fix applied:** pushed an empty commit (`git commit --allow-empty`) to `observability` to trigger the pipeline, which built, scanned, and pushed fresh images for all 7 services and auto-committed the tag bump back to the k8s manifests (see OBS-035 for that auto-commit behavior). Once ArgoCD picked up the new revision (manually re-triggered per OBS-037 rather than waiting on the 3-minute poll), all pods came up `1/1 Running` within about 2 minutes of the images landing in ECR.

**Status:** expected behavior, not a defect — documenting so a future full destroy/apply doesn't cause alarm when every pod is red immediately afterward. Worth remembering: **a full destroy/apply is not complete on its own** — it must be followed by a CI run (a real code push, or an empty commit like this one) before the cluster is actually serving traffic.

### OBS-039 — after a full destroy/recreate, the domain is unreachable because the registrar still delegates to the old (destroyed) Route53 zone

**Symptom:** after ArgoCD synced and every pod was `1/1 Running` (OBS-037, OBS-038 both resolved), `curl http://bookstore.<domain>/` and `curl http://api.bookstore.<domain>/books` both timed out — but `curl` straight to the ELB's DNS name with an explicit `Host:` header returned a correct `308` redirect for both hosts, proving the entire ingress → service → pod chain was actually healthy. `dig +short bookstore.<domain>` returned nothing at all, even against `8.8.8.8` (a public resolver, ruling out local network/SNI filtering — see the DNS/SNI issue documented earlier this session, which was a different, local-only problem).

**Root cause:** `module.route53`'s **public** hosted zone is a real `aws_route53_zone` resource with no `prevent_destroy` (deliberately removed in commit `797a526` ahead of this exact test) — so a full `terraform destroy` deletes it, and `terraform apply` creates a brand-new zone with a **new zone ID and new NS records** every time. `whois <domain>` confirmed the registrar (nic.xyz) was still delegating to the *previous* zone's nameservers (`NS-1229.AWSDNS-25.ORG`, `NS-156.AWSDNS-19.COM`, `NS-1592.AWSDNS-07.CO.UK`, `NS-762.AWSDNS-31.NET`) — completely different from the new zone's actual NS records (`ns-1281.awsdns-32.org`, `ns-1662.awsdns-15.co.uk`, `ns-72.awsdns-09.com`, `ns-864.awsdns-44.net`, from this apply's `route53_public_name_servers` output). Nothing in Terraform or CI updates the registrar — domain registration lives entirely outside AWS.

**Fix:** not something Terraform/AWS CLI can do — requires logging into the domain registrar and updating its NS delegation to the new zone's 4 nameservers (available as a Terraform output: `route53_public_name_servers`). Left for the user to do manually.

**Status:** known, manual step required after every full destroy/recreate cycle. A durable fix isn't really possible without either (a) never destroying the public zone (give it `prevent_destroy` again, accepting that a full destroy leaves the zone behind as a real orphan cost), or (b) automating the registrar update via its API if the registrar supports one — nic.xyz/nowhere in this repo currently does. Worth calling out explicitly in `DEPLOYMENT.md`'s destroy/recreate instructions so it isn't a surprise next time.

### OBS-040 — Grafana dashboard auto-import silently imported nothing: a single large dashboard's JSON blew past Linux's per-argument limit, killing the whole import under `set -e`

**Symptom:** after a fresh `terraform apply`, Grafana came up healthy with all 3 datasources correctly provisioned, but `curl .../api/search?type=dash-db` returned `[]` — zero dashboards, on every apply, not just this one. `/var/log/grafana-dashboard-import.log` showed:
```
/usr/local/bin/import-grafana-dashboards.sh: line 21: /usr/bin/curl: Argument list too long
```

**Root cause:** `import-grafana-dashboards.sh` (templated into `modules/monitoring-ec2/user-data.sh.tftpl`) downloads each community dashboard's JSON into a shell variable, then passes it inline as a single `curl -d "{...$json...}"` argument. Dashboard `1860` ("Node Exporter Full") is genuinely large — confirmed live at 683,275 bytes. `getconf ARG_MAX` on the box reports 2MB, so 683KB looks like it should fit — but Linux caps any **individual** exec argument at `MAX_ARG_STRLEN` (32 pages = 131,072 bytes / 128KB), a separate, much smaller limit than total `ARG_MAX`. A single argument over ~128KB always fails with `E2BIG`/"Argument list too long" regardless of how much headroom `ARG_MAX` has. Reproduced directly: `curl -d "$json"` with the same 683KB string failed identically outside the script. Because the script runs under `set -e` and this `curl` call wasn't guarded by `||`, the whole script died right there — dashboard `315` ("Kubernetes cluster monitoring"), which is small enough to have worked fine, never even got attempted.

**Fix applied live and in git:** rewrote `import_dash()` to download the dashboard JSON to a file, use `python3` to wrap it into the full import payload (also written to a file), and pass it to curl as `-d @/tmp/payload-<id>.json` — curl reads the request body from the file directly, so only a short filename ever becomes an argv string, sidestepping `MAX_ARG_STRLEN` entirely regardless of how large a future dashboard's JSON is. Also added a guard around the import `curl` call so one dashboard failing (network blip, dashboard ID retired upstream, etc.) logs and continues instead of killing the rest of the import. Both dashboards imported successfully live via the fixed logic, then the fix was committed to `modules/monitoring-ec2/user-data.sh.tftpl` so a future `terraform apply` doesn't need this repeated by hand.

**Status:** fixed live and in git. Confirmed via `GET /api/search?type=dash-db` returning both `Node Exporter Full` and `Kubernetes cluster monitoring (via Prometheus)`.

### OBS-041 — `ubuntu` was never added to the `docker` group, so `make monitoring-status`/`monitoring-logs`-style plain `docker` commands always needed `sudo` they never had

**Symptom:** SSH'd into the monitoring EC2 and ran a plain `docker ps` (no `sudo`) to check container health — failed with `permission denied while trying to connect to the Docker daemon socket`. `groups` showed `ubuntu adm dialout cdrom floppy sudo audio dip video plugdev netdev lxd` — no `docker` group anywhere, despite Docker CE being installed and all 5 containers actually running fine under it.

**Root cause:** `modules/monitoring-ec2/user-data.sh.tftpl` installs Docker from Docker's own official apt repository (`docker-ce`/`docker-ce-cli`/`containerd.io`), not Ubuntu's `docker.io` package. Some distro-packaged installs auto-add the invoking user to the `docker` group as a postinst step; Docker's own upstream packages deliberately do not — creating the `docker` group and adding users to it is left entirely to the operator. Nothing in this project's bootstrap script ever did that step, so every monitoring EC2 this project has ever provisioned has had this gap; it just hadn't been hit because prior checks (`make monitoring-status`) apparently either weren't run with a plain `docker ps` in a plain shell, or were run before the group requirement was noticed.

**Fix:** added `usermod -aG docker ubuntu` right after the Docker install step in `modules/monitoring-ec2/user-data.sh.tftpl`. Since this runs during boot's `user-data`, before anyone has SSH'd in yet, the group membership is already in place by the time the first real SSH session starts — no "log out and back in" caveat applies here the way it normally would for an already-running session.

**Status:** fixed in git for future applies. Not retroactively fixed on any already-running instance from before this fix (would need a manual `usermod` + reconnect on any such box, or a fresh `terraform apply`).

### OBS-042 — kube-state-metrics silently went from "all pod data" to "zero pod data" ~15 minutes after every boot: it never re-reads its refreshed token

**Symptom:** Grafana's "Kubernetes cluster monitoring" dashboard showed `N/A` across every panel. `docker ps` showed `kube-state-metrics` as `Up` (no crash-loop), and Prometheus's `/targets` page showed the `kube-state-metrics` job as `up` (the HTTP scrape itself succeeds — it's serving its own process metrics fine). But `curl .../api/v1/query?query=kube_pod_info` against Prometheus returned an empty result set, and `docker logs kube-state-metrics` was flooded with:
```
W reflector.go:547 failed to list *v1.Pod: Unauthorized
E reflector.go:150 Failed to watch *v1.Pod: failed to list *v1.Pod: Unauthorized
```
(and the same for every other watched resource type — `Unauthorized`, a 401, not `Forbidden`/403).

**Root cause:** `refresh-kube-token.sh` (see OBS-033) runs via cron every 10 minutes and correctly writes a fresh `aws eks get-token`-issued bearer token to `/opt/monitoring/kube/config` on disk. But `kubectl` / client-go — including inside the `kube-state-metrics` container, which is given `--kubeconfig=/root/.kube/config` at container start — loads a **static bearer token** kubeconfig exactly once, when the REST client is constructed, and never re-reads the file afterward. EKS-issued tokens are short-lived (~15 minutes). So every `kube-state-metrics` container works fine for roughly its first 15 minutes of uptime, then silently and permanently loses the ability to list/watch anything — the cron job keeps faithfully refreshing a file on disk that the already-running process will never look at again. Since Docker Compose's `restart: unless-stopped` only restarts on a crash, and this failure mode isn't a crash (the process just returns errors and keeps running), it never self-heals.

**Fix applied live and in git:** appended `docker restart kube-state-metrics || true` to the end of `refresh-kube-token.sh` (the `|| true` because the very first invocation of this script, at boot, runs before `docker compose up -d` has created the container at all — a hard failure there would abort the entire boot script under `set -e`). Now every 10-minute token refresh also recycles the container, so it never runs on a token older than 10 minutes. `kube-state-metrics` is fully stateless (everything it serves is derived live from list/watch against the API server), so restarting it every 10 minutes is safe — a few seconds of `up=0`/empty metrics per restart, not a real gap.

**Status:** fixed live and in git. Confirmed via `curl .../api/v1/query?query=count(kube_pod_info)` returning a real pod count (`38`) immediately after a manual restart, and Grafana's Kubernetes dashboard populating.

### OBS-043 — `modules/monitoring-ec2/user-data.sh.tftpl` outgrew AWS's 16KB `user_data` limit

**Symptom:** adding the kubelet-cadvisor scrape job (and its accompanying comments) to the monitoring EC2's boot script broke `terraform plan` with:
```
Error: expected length of user_data to be in the range (0 - 16384), got #!/bin/bash...
```

**Root cause:** the script had been growing incrementally across many OBS-0xx fixes (each with its own explanatory comment) and was already close to the 16KB ceiling AWS enforces on raw EC2 `user_data`. The cAdvisor addition tipped it over.

**Fix:** trimmed the more verbose inline comments (the full narrative for each already lives in this file, no need to duplicate it in the shell script) and, more durably, switched `aws_instance.monitoring` from `user_data` to `user_data_base64 = base64gzip(templatefile(...))`. EC2/cloud-init auto-detects and decompresses gzip user-data at boot, and the 16KB limit applies to the *compressed* bytes — buying real headroom instead of needing another round of comment-trimming the next time this script grows. Also added `user_data_replace_on_change = true`, which wasn't previously set: without it, changing `user_data`/`user_data_base64` only updates the instance's stored attribute at the AWS API level — cloud-init runs user-data exactly once, on first boot, so an already-running instance would silently never pick up script changes at all. This box is fully stateless (Docker Compose + auto-imported dashboards), so replacing it on every script change is correct, not a risk.

**Status:** fixed in git. Confirmed via a real apply — new instance booted clean with the gzip'd script and all 5 containers came up.

### OBS-044 — wired up real per-pod CPU/memory usage via kubelet cAdvisor (not an incident — a gap closed on request)

Previously, kube-state-metrics only ever exposed pod *requests/limits/status* — never actual resource usage. Added a `kubelet-cadvisor` Prometheus scrape job hitting each node's kubelet directly (`https://<node-ip>:10250/metrics/cadvisor`), which required three real infra additions, none of which existed before: a security-group rule (port 10250, same shared cluster SG as the existing node-exporter/API-server rules), a `ClusterRole`/`ClusterRoleBinding` granting `get` on `nodes/proxy`/`nodes/metrics`/`nodes/stats` (new `observability-rbac.tf`, bound to a stable `monitoring-metrics-readers` group set on the monitoring EC2's access entry — not the raw IAM principal ARN, which embeds the specific EC2 instance ID and would break on every replacement), and a plain bearer-token file Prometheus re-reads on every scrape (unlike kube-state-metrics's kubeconfig, see OBS-042 — no restart needed for this one). Verified live: `container_memory_working_set_bytes` returning 147 real series with actual pod names and byte values. See `docs/OBSERVABILITY.md`'s "Real per-pod CPU/memory usage" section for the full wiring.

### OBS-045 — wired up app-level `/metrics` (prom-client) scraping via the API server's pod-proxy (not an incident — a gap closed on request)

App pods' own `prom-client` `/metrics` endpoints were real but never scraped (see the now-removed gap in `docs/OBSERVABILITY.md`'s history). The obvious fix — a `file_sd_configs` target list of pod IPs, same pattern as node-exporter/kubelet — doesn't actually work here: pod IPs and ClusterIP Services are only routable from inside the cluster's pod network (or from a node itself, via kube-proxy), and the monitoring EC2 is neither. Two real options existed: open a security-group rule for direct pod-IP reachability (requires per-service port rules and, worse, a live pod-IP discovery cron since pod IPs churn on every restart/redeploy — no static file_sd would stay correct), or scrape through the API server's existing `pods/proxy` subresource, reusing the already-open 443 route to the API server with zero new network surface. Went with the latter.

**Implementation:** a `kubernetes_sd_configs` job (`role: pod`, `api_server` pointed at `module.eks.cluster_endpoint`, templated so it can't go stale the way OBS-032's hardcoded IP did) discovers all pods cluster-wide, then `relabel_configs` (1) keeps only pods annotated `prometheus.io/scrape: "true"`, (2) rewrites `__metrics_path__` to `/api/v1/namespaces/<ns>/pods/<pod>:<port>/proxy/<path>` using the pod's own `prometheus.io/port`/`prometheus.io/path` annotations, and (3) overrides `__address__` to the API server itself — so every matched pod is actually scraped *through* the API server, not directly. Added the `prometheus.io/scrape`/`port`/`path` annotations to all 6 app service pod templates (5 microservices + the old `backend` Rollout). RBAC: extended the existing `monitoring-kubelet-reader` `ClusterRole` (see OBS-044) with `get` on `pods/proxy` — same authorization shape as the kubelet scrape, just a different subresource.

**A side effect worth knowing, not a bug:** this scrapes *any* pod in the cluster carrying that annotation, not just the 6 app services — `cert-manager`'s own pod ships one by default in its upstream Helm chart, and now shows up in the `app-metrics` job too. Harmless (it's real data from a real component), just not something explicitly asked for.

**Status:** fixed live and in git. Verified via `up{job="app-metrics"}` returning 7 targets (all 6 app services + cert-manager) all `1`, and `process_cpu_user_seconds_total{job="app-metrics"}` returning real per-pod data.

### OBS-046 — deleted the old backend monolith entirely (not an incident — the deferred cutover finally executed)

Confirmed live before touching anything: `backend-service` had zero ingress routes (only `bookstore.<domain>` → `frontend-service` exists in `k8s/base/ingress/ingress.yaml`), and a grep of `client/src` turned up zero references to `backend-service` anywhere — the new frontend calls only `api-gateway`. So the `backend` Rollout was running, consuming a pod slot and DB connections, for genuinely nothing reaching it. This was the deliberately-paused final task from Plan 4 (see `docs/FUTURE_IMPROVEMENTS.md`'s "lessons learned" — irreversible deletion of a once-production path was left for its own explicit go-ahead, not automated through).

**What got deleted**, in full:
- `k8s/base/backend/` (Rollout + Service), `configmaps/backend-config.yaml`, `database/schema-init-job.yaml` (backend's own DB bootstrap — **not** the shared `/bookstore/db-credentials` secret, which `catalog`/`user`/`order`/`notification`'s own schema-init jobs still depend on and was left untouched), `monitoring/analysis-template.yaml` (backend's canary `AnalysisTemplate` — meaningless without the Rollout it gated), `overlays/prod/hpa-backend.yaml`
- `backend-pdb` from `pdb.yaml`; `backend-policy` and frontend's now-dead egress-to-backend rule from `network-policy.yaml`
- the `db-secret` `ExternalSecret` (backend's only consumer) from `secrets/external-secret.yaml` — the `ClusterSecretStore` in that same file was **kept**, since every microservice's own `ExternalSecret` references it by name
- `backend/` source directory entirely (Dockerfile, app.js, tests, package.json)
- 6 CI steps (install/test/npm-audit/build/Trivy-scan/push) and the `BACKEND_REPO` env var + its `kustomize edit set image` line in `.github/workflows/ci-cd.yml`
- the `bookstore-backend` ECR repository, via `terraform apply` (`force_delete = true` on the module already — all image history permanently gone) — required editing `modules/ecr/main.tf`'s hardcoded `locals.repos` list (backend was one of two always-created repos alongside frontend, not part of the removable `extra_repos` list) and dropping the now-dangling `backend_repo_url` output from both `modules/ecr/outputs.tf` and root `outputs.tf`

**A real finding along the way:** after pushing and letting ArgoCD auto-sync (`prune: true`), every backend resource pruned cleanly from the live cluster except the `db-secret` `ExternalSecret` — it stayed present, `status.resources` showing no health/sync status for it at all, minutes after `Synced`. Root cause: it carried `argocd.argoproj.io/hook: PreSync` — **ArgoCD's normal prune-on-removal-from-git diff doesn't clean up resources that were originally applied as sync hooks**; hooks are lifecycle-managed by their own `hook-delete-policy` at the time of the sync that created them, not by the general prune mechanism for the ongoing desired-vs-live diff. Once a hook resource's manifest is deleted from git entirely (not just changed), nothing automatically deletes the orphaned live object. Fixed with a one-off `kubectl delete externalsecret db-secret -n bookstore` — legitimate here since the resource no longer exists in git and a fresh cluster provisioning would never create it. Worth remembering for any future deletion of a resource that carries an ArgoCD hook annotation: **expect to delete it manually**, prune won't do it.

**Verification:** `kubectl kustomize k8s/overlays/prod` built clean with zero backend references (one grep false-positive: Ingress's own `spec.backend` field, unrelated). Live cluster post-sync: only `frontend`/`frontend-service` + shared namespace resources (`Namespace`, `ResourceQuota`, `StorageClass`, `ClusterIssuer`, `ClusterSecretStore`, `Ingress`, `NetworkPolicy`, `PodDisruptionBudget`) remain in `bookstore` namespace. `frontend` pods `2/2 Running`, TLS cert `Ready=True`, `ClusterIssuer` `Ready=True`.

**Status:** done. The Application's top-level health briefly showed `Degraded` with a stale `lastTransitionTime` even after a hard refresh and with every individual resource reporting no unhealthy status — appears to be an ArgoCD status-cache artifact (the `api-gateway` Application has shown the same cosmetic `Degraded` label all session despite being repeatedly curl-verified healthy), not a real problem.

### OBS-047 — both auto-imported Grafana dashboards were empty, on every single apply, for two unrelated reasons

**Symptom:** user reported "pod cpu/memory usage, system services cpu/memory usage dashboard empty" — both Grafana dashboards imported (see OBS-040) showed blank panels despite Prometheus itself having confirmed real data (per OBS-044/OBS-045 verification earlier the same day).

**Root cause #1 (Node Exporter Full, dashboard 1860):** its `$job`/`$node` template variables are Grafana single-select variables with no `includeAll` and no hardcoded default. When the dashboard is imported via the API (as `import-grafana-dashboards.sh` does), Grafana evaluates the variable's `label_values(...)` query at import time to populate `current` — but the import runs in a race against Prometheus's first scrape cycle, so `current` frequently saves as empty. Once empty, every panel's PromQL interpolates `job=""`, matching nothing, and **nothing about this self-heals later** — the variable doesn't re-evaluate just because real data eventually shows up; it stays stuck on its saved (empty) value until a human opens the dashboard and picks from the dropdown, or something else sets it programmatically.

**Root cause #2 (Kubernetes cluster monitoring, dashboard 315):** unrelated to timing — this dashboard's `$Node` variable queries `label_values(kubernetes_io_hostname)`, a label that **does not exist anywhere in this Prometheus at all** (confirmed via `/api/v1/series` returning zero matches). This is an old community dashboard assuming a kube-state-metrics label convention this setup doesn't produce. No amount of waiting or variable-poking fixes this one — the panels are querying data that fundamentally isn't there under that name.

**Fix:**
1. For 1860: `import-grafana-dashboards.sh` now polls Prometheus for `node_uname_info` before considering the import complete, then explicitly PATCHes the saved dashboard's `job`/`node` `current` values via the Grafana API (`job=node-exporter`, `node=<a real instance from the live query>`). The dashboard's `uid` (`rYdddlPWk`) is stable across imports (baked into grafana.com's exported JSON), so it's safe to target directly.
2. For 315: dropped entirely, replaced with a small custom dashboard (`modules/monitoring-ec2/dashboards/pod-node-resources.json`) built against metrics this setup actually exposes — per-pod CPU/memory usage (kubelet cAdvisor, see OBS-044), node CPU/memory usage (node-exporter), pod status by phase, container restart rate. File-provisioned (dropped into the existing `dashboards/` provisioning path already watched by Grafana's file provisioner, `updateIntervalSeconds: 30`), not API-imported — simpler and more robust than fighting grafana.com's download/variable quirks for a dashboard this project owns outright.

**Status:** fixed live and in git. Verified on a freshly replaced instance (not just the live-patched one): both dashboards' variables/panels populate correctly with zero manual steps, confirmed via direct Prometheus queries matching every panel's expression (36 pod series for CPU/memory, 3 node series for system usage).

### OBS-048 — added pod-level/traffic alert rules + a cluster overview dashboard, verified live with a real fire-and-resolve cycle (not an incident — a feature request, documented for the demo methodology)

User asked for pod CPU/memory and traffic alerts, plus a live demonstration that they actually fire, plus a cluster-wide dashboard (kept the existing per-pod one too, not a replacement). Four new rules added to `rules/bookstore.yml`: `HighPodCPUUsage`, `HighPodMemoryUsage` (both from kubelet cAdvisor, OBS-044), `HighRequestRate`, `HighErrorRate` (both from the `app-metrics` job's `http_requests_total` counter, OBS-045). All four use short `for:` windows (1-2m, vs. 5-10m on the pre-existing node-level alerts) specifically so a demo doesn't require a sustained multi-minute condition.

**Live verification, not just "should work":**
1. `kubectl run cpu-stress-demo --image=polinux/stress --namespace=default -- stress --cpu 2 --timeout 400s` — a throwaway pod with no NetworkPolicy concerns (doesn't need network, and `default` namespace has none anyway). cAdvisor picks up **any** pod's container metrics regardless of namespace or the `prometheus.io/scrape` annotation gating (that annotation only gates the separate `app-metrics` job) — no extra wiring needed.
2. A sustained `curl` loop against the real ELB, `Host: api.bookstore.<domain>` header, hitting `/books`. **First attempt used plain HTTP and generated almost no signal** — `nginx.ingress.kubernetes.io/force-ssl-redirect: "true"` makes ingress-nginx issue the `308` redirect at the nginx layer itself, before ever proxying to `api-gateway`, so the request never touches the app and `http_requests_total` barely moves. Fixed by switching the load generator to `https://` (`-k` to skip cert verification from the ELB's raw hostname) — real backend hits started immediately (api-gateway went from 0.6 req/s to 17.5 req/s).
3. Polled `/api/v1/alerts` — both `HighPodCPUUsage` (`1.54 cores`) and `HighRequestRate` (`api-gateway 17.5 req/s`, `catalog-service 17.2 req/s`) reached `state: firing` within ~2 minutes. Cross-checked in Alertmanager's own `/api/v2/alerts` — same two alerts, `state: active`. Bonus: `HighCPUUsage` (the pre-existing node-level alert) went to `pending`, since the stress pod's 2 cores saturated its entire node.
4. Cleaned up (killed the load loop, deleted the stress pod) and re-polled — `0` active alerts within a few minutes, confirming the full fire→resolve lifecycle, not just a one-way trip.

**Status:** done, verified live end-to-end. See `docs/OBSERVABILITY.md`'s alert table and dashboard list for the durable reference.

### OBS-049 — full codebase review: 16 real findings across app code, k8s manifests, and Terraform, all fixed

Ran three parallel audits (Terraform infra, k8s manifests, app source + CI) specifically for correctness bugs and unused/redundant infrastructure, then independently verified the highest-impact findings against the real code before fixing anything (reading the actual file, not trusting the audit's citation blind). All 16 fixed in one pass; full test suite (78 tests across 5 services + client) and every `kubectl kustomize` overlay confirmed still green afterward.

**Real bugs fixed:**
- `client/src/pages/Update.jsx` never fetched the existing book before rendering the edit form — every field started blank, so editing one field wiped the rest via the PUT. Added a `GET /books/:id` route to catalog-service (didn't exist at all) and a `useEffect` fetch + controlled inputs in the form.
- All 4 DB-backed services (`services/{catalog,user,order,notification}-service/index.js`) used `mysql.createConnection()` — a single connection with no `.on('error', ...)` listener, so any DB blip (RDS failover, idle `wait_timeout`) was an unhandled exception that crashed the whole process. Switched to `mysql.createPool()` — same `.query()` API, but a pool evicts and replaces broken connections per-query instead of crashing.
- `services/order-service/app.js`'s checkout handler ran its per-item `INSERT` loop and the cart-clearing `DELETE` with no transaction — a failed insert partway through left prior inserts committed (a phantom order) and never cleared the cart. Rewrote using `db.promise()` + `beginTransaction`/`commit`/`rollback`, all-or-nothing.
- `modules/security/main.tf`'s RDS ingress rule opened port 3306 to the entire VPC CIDR despite its own description claiming "EKS nodes only." Scoped to just the 4 EKS-node private subnets via a new `local.eks_node_subnet_cidrs`.
- `variables.tf`'s `secondary_region` defaulted to a non-empty region, and both `modules/rds` and `modules/ecr` gated their cross-region replication on `secondary_region != ""` — so a live Secrets Manager replica and full ECR image replication were created in us-west-2 on every default apply, regardless of DR intent. This is the actual mechanism behind OBS-029's "orphaned ECR repos in us-west-2" mystery. Added `enable_dr_replication` (default `false`); the root module now only passes a real region through when that's true.
- 4 single-replica services (`catalog`/`user`/`order`/`notification`-service) each had a PDB requiring `minAvailable: 1` while running `replicas: 1` — mathematically blocks any voluntary eviction of the only pod forever (`kubectl drain`, EKS managed-node-group upgrades, autoscaler consolidation all hang). Changed to `maxUnavailable: 1`.
- `k8s/services/api-gateway/base/network-policy.yaml`'s egress rules to catalog/user/order used the Service port (80) instead of the actual container port (3000) — NetworkPolicy egress matching is against the real destination pod port, not any Service's port. Currently dormant (no NetworkPolicy-enforcing CNI installed in this cluster), but would silently block all api-gateway traffic the moment one is turned on.
- `services/user-service/app.js`'s `jwt.verify()` had no `algorithms` restriction, unlike api-gateway's equivalent check on the same secret (which correctly pins `HS256`) — the standard setup for JWT algorithm-confusion issues.

**Real gaps closed:**
- No rate limiting anywhere on `/auth/login`/`/auth/register` — added `express-rate-limit` (20 requests/15min per IP) to user-service.
- CI (`.github/workflows/ci-cd.yml`) ran `npm ci` and `npm audit` for the frontend but never `npm test` — the 18 documented frontend tests never ran in CI. Added the test step.
- `catalog-service`'s `POST`/`PUT`/`DELETE /books*` routes returned the raw mysql2 error object to the client on failure (`res.send(err)`) — information disclosure. Sanitized to generic messages, still logged server-side.

**Dead infrastructure removed:**
- `module.acm` — a full DNS-validated ACM certificate whose output was referenced nowhere; TLS is actually handled by cert-manager/Let's Encrypt, and CloudFront provisions its own separate cert. Deleted the whole module.
- `aws_security_group.alb_frontend` and its 3 rules — never attached to anything; the real ingress LB (an NLB as of OBS-055; was a Classic ELB when this finding was written) is provisioned by the K8s cloud-controller entirely outside Terraform's SG management either way.
- Unused variables/outputs: `modules/eks`'s `vpc_id` input (never referenced in the module body), `modules/network`'s `region` variable (module uses `data.aws_region` instead) plus several vestigial commented-out blocks, and 6 outputs nothing in the repo consumed (`internet_gateway_id`, `nat_gateway_id`, `rds_private_zone_id`, `rds_record_fqdn`, `node_group_role_arn`, `ingress_nginx_namespace`, `argocd_namespace`).

**Simplification:**
- `main.tf`'s 4 near-identical DB-credential blocks (catalog/user/order/notification — `random_password` + `aws_secretsmanager_secret` + `aws_secretsmanager_secret_version`, ~110 lines) collapsed into one `for_each` over `local.db_service_credentials` (~35 lines). Secret names/paths in AWS are byte-identical to before, so nothing downstream (k8s `ExternalSecret`s referencing those exact paths) changed. Root-module outputs (`catalog_db_secret_arn` etc.) kept for backward compatibility, just re-pointed at the new addressing.
- `modules/monitoring-ec2`'s `eks_node_sg_id` variable actually held the EKS *cluster* security group, not a node-specific one — acknowledged in an inline comment but never renamed across 3 earlier fixes to the same file. Renamed to `eks_cluster_sg_id` everywhere.

**Status:** all 16 fixed and verified. Terraform state was empty at fix time (infra had been destroyed), so the Terraform changes carried zero live-migration risk — no `moved` blocks needed for the `for_each` refactor since there was no prior state to preserve. `terraform validate`/`plan` both clean (124 resources to add, down from 129 — matches the dead-infra removal). Every `kubectl kustomize` overlay builds clean. Full test suite green: 60 backend tests (9+12+20+4+15 across the 5 services) + 18 frontend tests, plus new tests added for the fixes themselves (`GET /books/:id`, checkout rollback-on-failure).

### OBS-050 — Fluent Bit never actually shipped a single log line to Loki, on any node this project has ever provisioned, for two independent reasons

**Symptom:** user asked directly whether Fluent Bit was collecting logs and sending them to Loki. `curl .../loki/api/v1/query?query={job="eks-containers"}` returned zero streams, on every node, despite the rest of the observability stack (node-exporter, kube-state-metrics, cAdvisor, app-metrics) all confirmed working. Confirmed via `kubectl debug node/<name> -it --image=busybox -- chroot /host ...` (no SSM agent registered, no direct SSH to worker nodes in this setup): `systemctl status fluent-bit` → `Unit fluent-bit.service could not be found` — it had never even been installed.

**Root cause #1 — the yum repo baseurl 404s.** `/var/log/custom-node-setup.log` showed `https://packages.fluentbit.io/amazonlinux/2/x86_64/repodata/repomd.xml: [Errno 14] HTTPS Error 404 - Not Found`. The repo config's `baseurl` had a `/$basearch/` segment (`.../amazonlinux/2/$basearch/`) that doesn't exist in Fluent Bit's actual current repo layout — confirmed against their live docs and directly: `.../amazonlinux/2/x86_64/repodata/...` → 404, `.../amazonlinux/2/repodata/...` (no arch segment) → 200. `yum install -y fluent-bit` failed outright on every single node this project has ever booted; nothing after it in that section of the script ever ran, silently, since the failure was contained to that one `[INPUT]`/`[OUTPUT]` block and the rest of `node-user-data.sh.tftpl` (node-exporter, which runs earlier) succeeded independently.

**Root cause #2 — even after installing Fluent Bit correctly, logs still didn't arrive.** Fixed root cause #1 live (`kubectl debug node` + a corrected repo config + `systemctl enable --now fluent-bit`) on all 3 running nodes — `fluent-bit.service` came up `active`, and `journalctl -u fluent-bit` showed it successfully tailing and parsing `/var/log/containers/*.log` (the `cri` parser worked). But every flush to Loki failed: `[error] [upstream] connection #NN to tcp://<monitoring-EIP>:3100 timed out after 10 seconds`. The security group was correctly scoped for VPC-internal traffic (`cidr_blocks = [var.vpc_cidr]`), but `LOKI_HOST` was templated from the monitoring EC2's **public** Elastic IP (`main.tf`'s `loki_url = "http://${aws_eip.monitoring.public_ip}:3100"`, passed into `module.eks`). EKS nodes live in private subnets — traffic from a private subnet to another instance's *public* IP within the same VPC doesn't route back cleanly (no public-IP hairpinning by default in a VPC), so every connection attempt timed out regardless of the security group being right.

**Why the public IP was used in the first place:** the monitoring EC2's actual private IP lives inside `module.monitoring_ec2`, which itself depends on `module.eks` (needs `cluster_name` for its own boot script). Having `module.eks` take `module.monitoring_ec2`'s private IP as a Terraform-time input would create a circular module dependency. The public EIP, a root-level resource independent of both modules, was the only value available without one.

**Fix:** discover the monitoring EC2's private IP at **boot time** via `aws ec2 describe-instances --filters "Name=tag:Name,Values=bookstore-monitoring"` (retried, since the node's own IAM policy for this call is created in the same apply as the node and can race propagation — see OBS-050's third finding below) — the same pattern `modules/monitoring-ec2`'s own `update-prom-targets.sh` already uses in reverse (monitoring EC2 discovering node IPs). This sidesteps the circular-dependency problem entirely, since it resolves via the AWS API at runtime instead of the Terraform graph at plan time, and it's also correct across EIP reallocation (a full destroy/recreate gets a new EIP every time — the private-IP discovery doesn't care). Required a new `ec2:DescribeInstances` IAM grant on the node role (`modules/eks/iam.tf`, read-only, same shape as the monitoring EC2's own existing grant). `modules/eks/variables.tf`'s `loki_url` variable removed entirely, replaced with `region`.

**A third, related finding along the way:** the monitoring EC2's own bootstrap failed on its very first boot with `AccessDeniedException` on `secretsmanager:GetSecretValue` for the Grafana admin password — its IAM role policy is created in the same apply as the instance, and IAM changes aren't instantly consistent. The exact same `aws secretsmanager get-secret-value` call succeeded seconds later with zero config changes, confirming a pure propagation race. Since this ran under `set -e` with no retry, it killed the *entire* monitoring stack on that boot (nothing after that line — Prometheus, Grafana, Loki, all of it — ever started), and since user-data only runs once, it never self-healed. Fixed by wrapping the call in a 10-attempt retry loop with a 6s backoff. Same retry pattern applied to the new node-side `ec2:DescribeInstances` discovery call for the identical reason.

**Status:** all three fixed live (on the nodes that were running at the time) and in git (`modules/eks/node-user-data.sh.tftpl`, `modules/eks/iam.tf`, `modules/eks/variables.tf`, `modules/monitoring-ec2/user-data.sh.tftpl`, `main.tf`). Verified end-to-end via the live fix: `journalctl -u fluent-bit` showed real container log chunks being read and parsed. Rolling the templated fix onto a fresh node-group launch template hit a separate infra blocker (this account's EC2 vCPU quota — see OBS-051) and is currently paused, not deployed — see OBS-051 for the full status.

### OBS-051 — rolling the OBS-050 Fluent Bit fix onto the node group hit this account's EC2 vCPU quota; node group pinned to its current launch template version until that's resolved

**Symptom:** `terraform apply` to pick up the OBS-050 node-user-data fix failed after ~20 minutes: `Error: waiting for EKS Node Group ... unexpected state 'Failed' ... NodeCreationFailure: Couldn't proceed with upgrade process as new nodes are not joining node group`. AWS itself rolled the node group back to its original 3 nodes — no pods were evicted, no capacity was actually lost, but the fix never landed.

**Root cause:** `aws_launch_template.nodes` picking up new user-data forces `aws_eks_node_group.this` to roll every node onto the new version, and EKS's managed rolling-update strategy needs surge capacity (extra instances) to do that without downtime. This account's `L-1216C47A` quota ("Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances") is 8 vCPUs. Steady state is already at 8: 3× `t3.medium` EKS nodes (2 vCPU each = 6) + 1× `t3.small` monitoring EC2 (2 vCPU) = 8. `aws autoscaling describe-scaling-activities` on the underlying ASG showed repeated `VcpuLimitExceeded` as EKS tried to scale desired capacity to 4 and then 5 to make room for the rolling replace.

**Not a code bug** — confirmed by checking what was actually running: only 4 real EC2 instances existed the whole time (3 node-group + 1 monitoring), never 8 of anything. "8" is the account's vCPU ceiling, hit exactly at steady state with zero headroom for any node-group launch-template change going forward, not just this one.

**Fix (chosen path — pause, don't shrink):** requested a quota increase to 16 vCPUs (`aws service-quotas request-service-quota-increase --service-code ec2 --quota-code L-1216C47A --desired-value 16`) rather than temporarily reducing `node_desired_size`. Reducing node count was considered and rejected: this cluster's 3 nodes are already near the t3.medium ENI pod-IP cap (15-19 pods/node against 17 allocatable) — the same tightness OBS-030/TF-014 documented when 2 nodes wasn't enough for all 5 microservices + gateway. Dropping to 2 nodes risked pods stuck `Pending`, a worse outcome than leaving the log-shipping fix temporarily un-rolled.

**Made durable, not just deferred:** added `lifecycle { ignore_changes = [launch_template[0].version] }` to `aws_eks_node_group.this` (`modules/eks/main.tf`). Confirmed via `terraform plan` that the node group and launch template no longer appear in the diff at all — any future `terraform apply` for unrelated changes won't re-attempt this same rolling update and fail again. The OBS-050 fix itself is untouched in git; only the *rollout* is paused. To actually deploy it: confirm the quota increase cleared (`aws service-quotas get-requested-service-quota-change`), remove the `ignore_changes` line (or `terraform apply -replace=module.eks.aws_eks_node_group.this`), and apply during a window where a brief rolling replace is acceptable.

**Status:** quota increase requested, pending AWS approval as of this entry. Node group pin is live and verified (`terraform plan` shows zero diff on `aws_eks_node_group.this`/`aws_launch_template.nodes`). Fluent Bit/Loki log shipping remains inactive on real infra until this is deliberately un-paused.

### OBS-052 — `terraform destroy`/failed-apply left the ingress-nginx LoadBalancer Service deleted, causing a real outage until caught

**Symptom:** after the OBS-051 node-group apply failed and rolled back, the app domain (`https://<domain>/`) was completely unreachable (`curl` timing out, `dig` returning nothing) — not a slow response, no route at all. `kubectl get svc -n ingress-nginx` showed only `ingress-nginx-controller-admission` (the webhook service); the actual `ingress-nginx-controller` LoadBalancer Service — the one thing that provisions the Classic ELB the whole app sits behind — was simply gone. The controller pod itself was still `Running` (1/1); only the Service object was missing.

**Root cause:** `module.eks_addons.null_resource.delete_ingress_nginx_lb` (`modules/eks-addons/ingress.tf`) has a `when = destroy` local-exec provisioner that runs `kubectl delete svc ingress-nginx-controller` — a deliberate workaround so a *real* `terraform destroy` doesn't leave an orphaned Classic ELB behind (Terraform's `helm_release` destroy doesn't reliably clean up a LoadBalancer-type Service's cloud resources on its own). `kubectl get events -n ingress-nginx` confirmed `DeletingLoadBalancer`/`DeletedLoadBalancer` fired ~60 minutes before the outage was noticed — during the OBS-051 apply's failure/retry cycle, something caused this resource to be destroyed and recreated (its destroy-time provisioner firing as a side effect), deleting the real Service, and — because `ingress-nginx` is a plain `helm_release` Terraform resource, not an ArgoCD `Application` with continuous self-heal — nothing reconciled it back on its own. Helm only re-applies its full manifest on an explicit `helm upgrade`/`terraform apply` touching that release; it does not watch for and repair drift the way ArgoCD would.

**Fix:** extracted the Service manifest from the Helm release's own stored state (`helm get manifest ingress-nginx -n ingress-nginx`) and `kubectl apply`'d it directly — Kubernetes provisioned a fresh Classic ELB immediately, confirmed all 3 node instances registered `InService` within seconds. Then re-ran `terraform apply` so `local.primary_alb_dns`'s auto-discovery (`argocd.tf`) picked up the new ELB hostname and updated the Route53 alias records (the DNS failover health check briefly showed `ServFail` — normal for a brand-new ELB DNS name in its first minute — and cleared on its own).

**Status:** fixed live, domain confirmed reachable again. No code/Terraform change was needed — `delete_ingress_nginx_lb`'s destroy-time behavior is intentional and correct for a genuine `terraform destroy`; the danger here was specifically a *failed, retried* apply cycle causing it to fire outside that path. Worth knowing if a future apply fails partway through touching `module.eks_addons`: check `kubectl get svc -n ingress-nginx` before assuming the app is still reachable, don't assume a failed apply is a no-op for already-applied resources.

### OBS-053 — added real email alert notifications (Alertmanager → SES SMTP), config.env-driven (not an incident — a feature request)

**Ask:** Alertmanager was firing alerts correctly (confirmed live in OBS-048) but nothing was actually notified — both receivers pointed at an unconfigured `localhost:5001` webhook stub. User asked for real email/Slack notification; email was chosen.

**Implementation:**
- `aws_sesv2_email_identity` for `var.alert_email` — SES starts new accounts in sandbox mode (both sender and recipient must be verified addresses), so using the same address for both means exactly one verification email to click, triggered automatically on `terraform apply`.
- A narrowly-scoped `aws_iam_user`/`aws_iam_user_policy` (`ses:SendRawEmail` only) plus `aws_iam_access_key`, for SES SMTP auth.
- **SMTP AUTH needs a password derived from the IAM secret key, not the raw key itself** — SES's own documented conversion (a fixed-date HMAC-SHA256 chain: date → region → `ses` → `aws4_request` → `SendRawEmail`, versioned and base64-encoded). No Terraform-native HMAC primitive exists for this, so a `null_resource` with a `local-exec` provisioner shells out to `python3` to compute it and writes the result straight to a new Secrets Manager entry (`/bookstore/alertmanager-smtp`, JSON: host/port/username/password/from/to) via `aws secretsmanager put-secret-value` — the derived password itself never enters Terraform state.
- The monitoring EC2's IAM role gained `secretsmanager:GetSecretValue` on this new secret (alongside its existing Grafana-password grant); `modules/monitoring-ec2/user-data.sh.tftpl` fetches it at boot (same IAM-propagation retry loop as the Grafana password, see OBS-050) and renders `alertmanager.yml`'s `global.smtp_*` block plus an `email_configs` block on both `default-webhook` and `critical-webhook` receivers — the existing webhook stub is left in place alongside it (harmless, and removing it was out of scope).
- **Configured via `config.env`, not a hand-edited `terraform.tfvars` or a shell env var**: `ALERT_EMAIL` in `config.env` → `python scripts/configure.py` (now requires it, alongside the existing `AWS_ACCOUNT_ID`/`AWS_REGION`/`DOMAIN`/`GITHUB_REPO`) → generated into `terraform.tfvars`. Matches the existing pattern for every other per-operator value in this repo instead of introducing a new mechanism.

**Verified:** `terraform plan`/`apply` clean; the local-exec script's `put-secret-value` succeeded (confirmed by reading the resulting secret back, minus the password); `terraform validate` clean after every edit. The monitoring EC2 was replaced (its `user_data_replace_on_change = true`, sequential destroy-then-create — no vCPU quota risk, unlike OBS-051's node-group surge) picking up the new `alertmanager.yml`.

**Status:** implemented and applied. Actual end-to-end delivery (a real alert firing and an email landing) depends on the SES verification link being clicked for `var.alert_email` — not yet confirmed as of this entry.

### OBS-054 — FinOps + standards audit (read-only), then implemented every finding that didn't need EC2 vCPU headroom

**Ask:** a cost/FinOps + industry-standards review, report-only first ("just want to know"), then "go ahead and implement them" with one hard constraint: this account's EC2 vCPU quota is fixed at 8 (see OBS-051) and steady-state usage is already at 8 (3× t3.medium node group + 1× t3.small monitoring EC2) — nothing implemented is allowed to need that raised.

**Findings and fixes:**
- **RDS defaulted to gp2, not gp3** — `storage_type = "gp3"` added to `modules/rds`. gp3 is both cheaper and faster per GB than gp2 at this size; zero downside.
- **Zero VPC endpoints anywhere** — added an S3 Gateway Endpoint (`modules/network`, free, no hourly/data charge) so ECR image-layer pulls and S3 API traffic stop transiting the single NAT Gateway's paid data-processing path. ECR interface endpoints were considered and deliberately skipped — real per-AZ hourly ENI cost, unclear net benefit at this project's pull volume.
- **CloudWatch log retention: only VPC flow logs were bounded (90d)** — EKS control-plane logs (all 5 log types) and RDS's 3 exported log streams (error/general/slowquery) had no Terraform-managed log group, so AWS default was indefinite retention. Added explicit `aws_cloudwatch_log_group` resources (30-day retention) in both `modules/eks` and `modules/rds`, ordered via `depends_on` so retention applies from the first log line instead of needing a later import.
- **CloudTrail S3 bucket: versioned, no lifecycle policy** — every log rewrite kept every old version forever at Standard storage class. Added `aws_s3_bucket_lifecycle_configuration`: Standard→IA at 30d, →Glacier at 90d, noncurrent versions expire at 365d. Current-version objects are never expired (audit trail stays retrievable), only tiered and the noncurrent pile is capped.
- **No cost-allocation tag beyond `Project`/`Environment`/`ManagedBy`** — added `CostCenter` (new `var.cost_center`, default `"bookstore-platform"`) to all three `default_tags` blocks in `providers.tf`.
- **EKS node root volume was unmanaged** — no `block_device_mappings` on the launch template meant the AL2 AMI's implicit (likely gp2) default was silently in use. Added an explicit gp3/20GB/encrypted block. Since the node group already carries the OBS-051 `lifecycle.ignore_changes` pin on `launch_template[0].version`, this has no effect on already-running nodes and won't trigger a rolling replace — it only takes effect on the next full `create`.
- **ingress-nginx: `replicaCount=1` with a PDB `minAvailable=1`** — the exact same undrainable-single-replica anti-pattern OBS-049 fixed for the 4 single-replica backend services, missed there because it's a Helm `set` value in `modules/eks-addons/ingress.tf`, not a `k8s/` YAML file that sweep covered. Every request in the app — every static asset, every API call — passes through this controller; at 1 replica it was a hard SPOF. Fixed: `replicaCount=2`, PDB switched to `maxUnavailable=1`. Runs as pods on the existing fixed node group — no new EC2 instances, no vCPU impact, safe under the constraint.
- **Dead in-cluster-MySQL files** (`k8s/base/database/mysql-statefulset.yaml`, `mysql-service.yaml`, `mysql-init-configmap.yaml`) — unreferenced by any `kustomization.yaml`, confirmed via grep. Deleted (see the note now in `ARCHITECTURE.md`/`KUBERNETES.md`).

**Deliberately not implemented, and why:**
- **Cluster Autoscaler / Karpenter** — the actual fix for HPAs being capped by a fixed 3-node group (all 6 HPAs are correctly configured but can't scale past whatever spare capacity those 3 nodes have), but its entire value proposition is adding node capacity on demand — exactly what the vCPU constraint rules out here.
- **Spot instances** — same total vCPU count as On-Demand, but Spot is tracked against a *separate*, unconfirmed AWS quota, and adds interruption risk to a node group that's already in a fragile pinned state (OBS-051). Not touching it mid-pin.
- **Reserved Instances / Savings Plans on RDS + the monitoring EC2** — the single biggest dollar lever identified, but it's a real financial commitment made in the AWS Billing console, not a Terraform resource — intentionally left as a manual decision for whoever holds the account.

**Verified:** `terraform validate` clean (one warning surfaced and fixed along the way — the S3 lifecycle rule needed an explicit `filter {}` block to apply account-wide). Applied 2026-08-15 in the same `terraform apply` that rebuilt the stack from scratch — see OBS-055's own entry for the two real issues that surfaced during that apply (both unrelated to this entry's changes: two orphaned CloudWatch log groups, and an AWS-side `vpc-cni` addon config schema change).

**Status:** implemented, validated, applied.

### OBS-055 — full rebuild after destroy: two real issues hit and fixed, neither one caused by this session's own changes

**Context:** ran `terraform apply` from a fully-destroyed state (142 resources) to bring the stack back up with every OBS-054 fix included. Two independent, real errors surfaced partway through — both pre-existing account state or an upstream AWS change, not bugs in this session's Terraform edits.

**Issue 1 — two orphaned CloudWatch log groups blocked their own `aws_cloudwatch_log_group` resources from being created:**
```
Error: creating CloudWatch Logs Log Group (/aws/eks/bookstore-eks/cluster): ...
  ResourceAlreadyExistsException: The specified log group already exists
Error: creating CloudWatch Logs Log Group (/aws/rds/instance/bookstore-db/error): ...
  ResourceAlreadyExistsException: The specified log group already exists
```
**Root cause:** CloudWatch log groups for EKS control-plane logs and RDS log exports are not owned by the EKS cluster's or RDS instance's own lifecycle — `terraform destroy` deletes the cluster and the database, but the log groups they were writing to are separate AWS resources that simply keep existing, orphaned, with old data still in them (532MB on the EKS one, going back to a prior incarnation of this same cluster name). OBS-054 added `aws_cloudwatch_log_group` resources for these specifically to bound their retention — but that means Terraform now tries to *create* them fresh on every from-scratch apply, and AWS rejects a `CreateLogGroup` call for a name that already exists, orphaned or not.

**Fix considered and rejected:** `terraform import` — doesn't work here. The `kubernetes`/`helm`/`kubectl` Terraform providers are configured against `module.eks`'s outputs (cluster endpoint, CA cert), which don't exist until the EKS cluster itself is created — but `terraform import` has to configure *every* provider up front, including ones whose config depends on a resource that doesn't exist yet. Chicken-and-egg, specific to `import`; `apply` doesn't have this problem because it builds the graph and only touches a provider's resources once its dependencies are satisfied.

**Fix:** deleted the two orphaned, contentless-going-forward log groups directly via `aws logs delete-log-group` (real AWS resources, real destructive action outside Terraform — confirmed explicitly before running), then re-ran `apply`. Terraform created them fresh, with the OBS-054 retention settings applied from the first log line.

**Issue 2 — AWS restructured the `vpc-cni` addon's `configuration_values` JSON schema:**
```
Error: creating EKS Add-On (bookstore-eks:vpc-cni): ...
  InvalidParameterException: ConfigurationValue provided in request is not
  supported: Json schema validation failed with error:
  [$.env.ENABLE_NETWORK_POLICY: is not defined in the schema and the schema
  does not allow additional properties]
```
**Root cause:** `modules/eks-addons/vpc-cni.tf` set `env.ENABLE_NETWORK_POLICY = "true"` — correct for the addon versions available when that code was first written. By this apply, the default `vpc-cni` addon version for this account/region (`v1.22.4-eksbuild.3`) had moved that setting to a **top-level** `enableNetworkPolicy` field; the old `env`-nested key isn't in the schema at all anymore and gets hard-rejected, not silently ignored. Confirmed via `aws eks describe-addon-configuration --addon-name vpc-cni --addon-version v1.22.4-eksbuild.3` — the setting genuinely moved, it wasn't renamed to something else nested differently.

**Fix:** `modules/eks-addons/vpc-cni.tf` now sets `configuration_values = jsonencode({ enableNetworkPolicy = "true" })` — no `env` wrapper. The code comment on that resource now documents exactly how this was diagnosed (`describe-addon-configuration`, not a guess), so the next time AWS changes this schema, the fix is "diff the schema again," not "guess again."

**Status:** both fixed, apply completed clean (`terraform apply` exit 0, all outputs populated). No errors on the resumed applies after each fix.

### OBS-056 — added a JWT refresh-token pattern (its load-balancer half was superseded before ever being applied — see OBS-057)

**Ask:** two independent, explicitly-requested fixes in one turn — replace the outdated Classic ELB (see OBS-010) with an NLB or ALB, and close the "can't instantly revoke a JWT" gap this project's own docs had named as a known, accepted tradeoff (see `ARCHITECTURE.md`'s auth section and `explaination/ARCHITECTURE_EXPLAINED.md`).

**Superseded, not applied:** this entry originally chose NLB (a one-line Service annotation on ingress-nginx, no new controller) over ALB, reasoning that ALB would require adopting the AWS Load Balancer Controller — a bigger change than seemed justified at the time. Before that NLB change was ever applied, a follow-up question ("isn't ingress-nginx itself outdated?") surfaced a much bigger fact: **ingress-nginx was officially retired by the Kubernetes project on 2026-03-31** — the whole premise of "just fix the annotation on the existing controller" no longer held, because the controller itself needed replacing regardless of load-balancer type. See OBS-057 for the real fix — the AWS Load Balancer Controller + ALB migration this entry's own reasoning talked itself out of, for a reason that turned out not to matter once the actual constraint was ingress-nginx's end-of-life, not just its default load-balancer type.

**JWT refresh tokens — short-lived access token + rotating refresh token, chosen over a blocklist — this part is real, current, and unaffected by OBS-057:** `services/user-service/app.js` — access tokens (still HS256 JWTs) dropped from 1h to 15 minutes; a new, separate, opaque refresh token (64 bytes of `crypto.randomBytes`, never a JWT) is issued alongside it on login, valid 7 days. Only the refresh token's SHA-256 hash is ever stored (same principle as password hashing), in a new `user_db.refresh_tokens` table (real `FOREIGN KEY ... ON DELETE CASCADE` to `users.id` — unlike the soft, unenforced cross-service references used elsewhere in this project, this is within one schema, so a real FK is the correct, standard choice here). Two new endpoints: `POST /auth/refresh` (rotates — the token just used is revoked, a new one issued, so a stolen-but-unused refresh token becomes worthless the instant the real client refreshes first) and `POST /auth/logout` (revokes a specific refresh token server-side — genuine, immediate revocation, something no plain-JWT scheme can do).

**Why refresh tokens over a blocklist:** a blocklist needs to be checked on every single request verifying a token — today that's `api-gateway`, which is a deliberately pure, stateless reverse proxy with **no database of its own at all**. Giving it one just to check a blocklist would be a bigger architectural change than adding two endpoints to `user-service`, which already owns a database and already owns auth. The refresh-token pattern keeps the gateway exactly as stateless as it already was; the only thing that changed is how often a client needs to ask for a new access token, and that new access token still gets verified the same stateless way it always did.

**Frontend:** `client/src/context/AuthContext.jsx` stores both tokens now; `logout()` fires a best-effort (not awaited, doesn't block the UI) `POST /auth/logout` to revoke the refresh token server-side. `client/src/api/api.js`'s response interceptor now attempts exactly one silent refresh on a 401 from any non-auth endpoint before falling back to the old clear-and-redirect-to-`/login` behavior — concurrent 401s dedupe onto a single in-flight refresh call (refresh rotates the token, so two simultaneous refresh calls would have the second one silently invalidate the first one's brand-new token).

**Verified:** `npm test` clean: 19/19 in `services/user-service` (10 new: refresh success/rotation/expired/missing-user, logout with/without a token, updated login test asserting a 15-minute expiry and a 96-hex-char refresh token), 24/24 in `client/` (new: silent-refresh-and-retry, refresh-token-missing, refresh-call-fails, already-retried-once, logout revocation call). Not yet deployed to the live cluster as of this entry — app code changes ship through the normal CI/CD → ArgoCD path, not a manual push.

**Status:** JWT refresh tokens implemented, tested, not yet deployed. Load-balancer portion superseded — see OBS-057.

### OBS-057 — ingress-nginx is EOL (retired 2026-03-31); replaced with the AWS Load Balancer Controller + ALB, per AWS's own official migration guidance

**Ask:** "isn't ingress-nginx itself outdated? I don't want it, replace it with the current industry standard" — asked as a direct follow-up right after OBS-056's NLB fix was planned but not yet applied.

**What's actually true, confirmed via live web search before acting on it (this is a real, serious, time-sensitive fact, not a style opinion):** the Kubernetes project's `kubernetes/ingress-nginx` — the controller this project used for its entire history — reached End-of-Life on 2026-03-31. The Kubernetes Steering and Security Response Committees announced the retirement in November 2025; the repository is now **read-only**: no new releases, no bug fixes, and critically, **no more CVE patches, ever**, for a component that terminates TLS and sits directly on the public internet. Roughly half of all cloud-native environments ran this controller — this was not a niche or already-obscure dependency. AWS itself published official migration guidance naming the exact replacement: *"migrate to AWS Load Balancer Controller to eliminate the security and compliance risks associated with running an unmaintained controller."* (See sources below — this finding was verified live, not recalled from training data, given the stakes of being wrong about a security-EOL claim.)

**The replacement, following AWS's own official guidance for EKS exactly:** the **AWS Load Balancer Controller** (`kubernetes-sigs/aws-load-balancer-controller`, Helm chart `aws/eks-charts`, pinned `3.4.0`), installed via IRSA in `modules/eks-addons/aws-load-balancer-controller.tf` — same IRSA shape as `external-secrets.tf`, IAM policy fetched verbatim from the controller's own published `docs/install/iam_policy.json` rather than hand-written (15 statements, easy to get subtly wrong by hand, and AWS periodically adds actions as the controller gains features). It provisions a real **Application Load Balancer (ALB)**, not another NLB — AWS's own guidance frames Ingress-object-plus-ALB-annotations as the *immediate* migration path, with Gateway API named as a *future* direction (`AWS Load Balancer Controller v3.0 supports Gateway API`), not the urgent one; adopting Gateway API now would mean a second, much larger migration (new CRDs — `GatewayClass`/`Gateway`/`HTTPRoute` — a different object model entirely) layered on top of an already-large one, for a benefit that isn't needed today. Worth revisiting Gateway API later as a deliberate, separate step, not bundled into fixing an EOL security issue under time pressure.

**Real, structural reason ALB — not another NLB fix — was correct, and why OBS-056's original NLB reasoning no longer applied:** OBS-056 chose NLB specifically to avoid installing a new controller, reasoning ingress-nginx itself was fine and only its default load-balancer type was wrong. That premise broke the moment ingress-nginx's EOL became the actual, dominant constraint — an NLB fix would have kept the exact unmaintained, unpatched, internet-facing component in place, solving a smaller problem while leaving the real one untouched. Once a controller replacement was unavoidable anyway, ALB (via the AWS Load Balancer Controller) became the *lower-effort* choice, not a bigger one — it's the officially-supported, first-class path this controller is designed around; NLB is also supported but ALB is what AWS's own migration guidance leads with.

**Everything that changed, file by file:**
- **New:** `ingress-cert.tf` (root) — a real, regional, DNS-validated ACM certificate (`aws_acm_certificate` + `aws_route53_record` validation records + `aws_acm_certificate_validation`). No ARN from it is injected into any Kubernetes manifest — the controller **auto-discovers** a matching ACM cert by comparing each Ingress's `spec.tls[].hosts`/`spec.rules[].host` against certs already issued in the account (a real, documented AWS Load Balancer Controller feature, confirmed via search before relying on it). This sidesteps a genuine chicken-and-egg problem: the cert doesn't exist until `terraform apply` creates it, but the Ingress YAML is static git content ArgoCD deploys on its own schedule, with no clean moment for Terraform to write a freshly-minted ARN into a checked-in file.
- **New:** `modules/eks-addons/aws-load-balancer-controller.tf` — IRSA role/policy + the Helm release, plus a destroy-time `null_resource.delete_ingress_objects` (deletes the two Ingress objects before `terraform destroy` touches the VPC — the controller adds a finalizer to each Ingress that blocks its deletion until the real ALB is actually torn down, more reliable than ingress-nginx's own teardown ever was, but still needs to run before a real destroy, same class of problem the old `delete_ingress_nginx_lb` workaround solved).
- **Deleted outright:** `modules/eks-addons/ingress.tf` (the `helm_release.ingress_nginx` and its destroy-time LB cleanup) and `modules/eks-addons/cert-manager.tf`. cert-manager had exactly one consumer in this project — the ingress TLS `ClusterIssuer` — and once TLS moved to an ACM cert the controller auto-discovers, cert-manager had nothing left to do; removed rather than left installed-and-unused, consistent with this project's established practice of not leaving dead infrastructure running (see the OBS-054 FinOps pass, the in-cluster-MySQL cleanup). `k8s/base/cert-manager/cluster-issuer.yaml` deleted alongside it, and its stale reference in `k8s/base/kustomization.yaml` and its patch in `k8s/overlays/prod/kustomization.yaml` (targeting the now-gone `ClusterIssuer`) both removed.
- **Rewritten:** `k8s/base/ingress/ingress.yaml` and `k8s/services/api-gateway/base/ingress.yaml` — `ingressClassName: nginx` → `alb`; `nginx.ingress.kubernetes.io/*`/`cert-manager.io/cluster-issuer` annotations replaced with `alb.ingress.kubernetes.io/*` ones (`scheme: internet-facing`, `target-type: ip` — real pod IPs via the VPC CNI, more direct than `instance` mode's NodePort hairpin — `listen-ports`, `ssl-redirect: "443"`). Both carry the **same** `alb.ingress.kubernetes.io/group.name: bookstore` — without it, AWS Load Balancer Controller provisions one ALB *per* Ingress object by default, which would mean two load balancers (and two bills) instead of the one this project has always run.
- **Fixed, a real bug caught by actually building the Kustomize output and reading it, not just diffing source:** both `k8s/base/network-policy/network-policy.yaml` and `k8s/services/api-gateway/base/network-policy.yaml` still gated ingress on `namespaceSelector: {kubernetes.io/metadata.name: ingress-nginx}` — but that namespace is gone, and more importantly, an ALB in `target-type: ip` mode connects **directly to pod IPs from its own ENIs in the VPC**, not from a pod in any namespace at all. Left unfixed, this would have silently blocked all real traffic to `frontend` and `api-gateway` the instant NetworkPolicy enforcement mattered (which it does — see OBS-049, VPC CNI network-policy enforcement has been on since that fix). Changed to `ipBlock: {cidr: 170.20.0.0/16}`, the same pattern already used throughout this project for traffic sources that can't be matched by a pod/namespace selector (e.g. every service's RDS egress rule).
- **Rewritten:** `argocd.tf`'s hostname-discovery mechanism. The old version (`data "kubernetes_service" "ingress_nginx"`) read a Service's status — safe to `kubectl wait` on immediately, because ingress-nginx's Service was created directly by a Terraform-managed `helm_release` with `wait = true`. The new load balancer comes from the AWS Load Balancer Controller reconciling an **Ingress object that Terraform doesn't create at all** — it's deployed by ArgoCD, asynchronously, after `kubectl_manifest.argocd_application` merely creates the ArgoCD `Application` pointing at it. `kubectl wait` needs its target resource to already exist or it fails immediately, not gracefully — so this is now a genuine two-stage wait: poll for the `bookstore-ingress` Ingress object's existence first (up to 5 minutes, a safety margin — ArgoCD's automated sync on a brand-new Application typically starts within seconds, not a full 3-minute poll cycle), then `kubectl wait` for its `status.loadBalancer.ingress[0].hostname` to populate. `data "kubernetes_ingress_v1" "bookstore"` replaces the old Service-based data source.
- **Changed again:** `modules/route53/main.tf`'s hosted-zone data source — the third distinct load-balancer type this one line has had to track across this project's history (Classic ELB → planned-but-never-applied NLB → ALB): `data "aws_lb_hosted_zone_id" "ingress_lb" { load_balancer_type = "application" }`. The module's own comment now spells out the full history so the next person doesn't have to reconstruct it from git blame.

**Blast radius, confirmed via `terraform plan` before applying:** 9 to add, 3 to change, 4 to destroy — the ACM cert + its 2 validation records + validation completion, the AWS Load Balancer Controller's IAM role/policy/Helm release, the new destroy-time null_resource, `null_resource.wait_for_alb_hostname` (replaces — expected, its trigger is `timestamp()`), the 3 Route53 alias records (in-place), and the 3 resources being removed (`cert_manager`/`ingress_nginx` Helm releases, the old destroy null_resource). RDS, the EKS cluster and node group, monitoring EC2, ArgoCD, Argo Rollouts, external-secrets, the VPC CNI/EBS-CSI/metrics-server addons — all untouched.

**Verified:** `terraform fmt`/`validate` clean. All 4 affected Kustomize trees (`k8s/base`, `k8s/overlays/prod`, `k8s/services/api-gateway/base`, `k8s/services/api-gateway/overlays/prod`) build cleanly with `kubectl kustomize` — this is exactly what caught the stale `ingress-nginx` NetworkPolicy selectors above; a diff review alone would have missed it, since the old and new YAML were both individually well-formed, just wrong together.

**Status:** implemented, validated, plan reviewed, applied — see OBS-058 for a DNS-delegation issue hit mid-apply, unrelated to the code itself.

Sources (fetched live, not recalled, given the stakes): [Ingress NGINX: Statement from the Kubernetes Steering and Security Response Committees](https://www.kubernetes.io/blog/2026/01/29/ingress-nginx-statement/), [Ingress NGINX Deprecation: EOL by March 2026](https://www.chkk.io/blog/ingress-nginx-deprecation), [Navigating the NGINX Ingress retirement: A practical guide to migration on AWS](https://aws.amazon.com/blogs/networking-and-content-delivery/navigating-the-nginx-ingress-retirement-a-practical-guide-to-migration-on-aws/), [The End of an Era: Transitioning Away from Ingress NGINX](https://opensource.googleblog.com/2026/02/the-end-of-an-era-transitioning-away-from-ingress-nginx.html).

### OBS-058 — ACM cert validation hung on `terraform apply`: registrar (GoDaddy) not delegated to the recreated Route53 zone's nameservers

**Symptom:** `terraform apply` for OBS-057's ALB migration hung on `aws_acm_certificate_validation.ingress: Still creating...` for over an hour, well past ACM's typical few-minutes DNS validation time, no error, no timeout yet.

**Root cause:** today's infra came up from a full `terraform destroy` + fresh `apply` (see OBS-055). `terraform destroy` deletes the Route53 public hosted zone along with everything else; the next `apply` creates a brand-new zone with **brand-new, randomly-assigned NS values** — Route53 doesn't reuse a domain's previous nameservers. ACM's DNS validation checks *public* DNS resolution for the CNAME validation records it expects in that zone, not Route53 directly — so until the registrar (GoDaddy, where `b17facebook.xyz` is registered) is manually updated to point at the new zone's 4 NS values, no public resolver can ever reach the validation records, and ACM validation waits forever (well, until Terraform's resource timeout).

**Diagnosis:** confirmed live, not assumed — `aws acm describe-certificate` showed `PENDING_VALIDATION` for both `b17facebook.xyz` and `*.b17facebook.xyz`; `whois b17facebook.xyz` showed the registrar's on-file nameservers didn't match `aws route53 get-hosted-zone --id <current zone> --query DelegationSet.NameServers` at all (stale values, likely left over from an even earlier zone incarnation); `dig NS b17facebook.xyz @8.8.8.8`/`@1.1.1.1` returned empty, confirming no public resolver could see any delegation yet.

**Fix:** not a code change — gave the user the exact 4 NS values from the live zone to enter at GoDaddy's registrar nameserver settings. After the update, `whois` reflected the correct values immediately (registry-level, near-instant), but public resolver caches (8.8.8.8, 1.1.1.1) took longer to reflect the change — registrar-to-resolver propagation timing is outside Terraform's, AWS's, or this project's control, typically minutes but occasionally longer depending on the resolver and previous record TTLs.

**Lesson for the next full destroy+recreate cycle:** a from-scratch `terraform apply` that recreates the Route53 public zone will **always** need this manual registrar step before any ACM cert or ALB depending on that zone can go live — worth doing the NS handoff *before* running `apply` for the ingress/ACM layer, not after kicking it off, to avoid an hour-plus idle wait mid-apply.

**Follow-up — fixed structurally, not just documented:** hit this exact issue again on a later full destroy+recreate cycle, and the user asked the right question: why does the zone get destroyed at all, if its only job is to hold a domain-registrar relationship that's supposed to be permanent? `modules/route53/main.tf`'s `aws_route53_zone.public` resource was replaced with a `data "aws_route53_zone" "public"` lookup by name — Terraform no longer creates or destroys this zone at all, so `terraform destroy` can't touch it and the NS values never change again after they're set once. A new one-time bootstrap, `scripts/init-domain.sh` (same idempotent create-if-missing pattern as `scripts/init-backend.sh`), creates the zone the first time and prints the NS values; every apply/destroy cycle after that just reads the zone that's already there. This is a stronger fix than OBS-018's `prevent_destroy` attempt (which was later deliberately removed — `prevent_destroy` still leaves the zone as a Terraform-managed resource that blocks a full `terraform destroy` outright, forcing the lifecycle block to be removed by hand to ever tear it down cleanly; a `data` lookup sidesteps that entirely, since destroy just has nothing to destroy).

### OBS-059 — ArgoCD `bookstore` AppProject was never Terraform-managed; a from-scratch rebuild deployed with no project at all

**Symptom:** after OBS-057/058's changes were pushed and CI/CD rebuilt fresh images, the `bookstore` ArgoCD Application sat in `SyncStatus: Unknown` with `InvalidSpecError: Application referencing project bookstore which does not exist` — no `bookstore` namespace, no pods, nothing deployed, despite Terraform apply having succeeded.

**Root cause:** `k8s/argocd/appproject.yaml` (added when AppProject scoping was introduced, see the OBS-054-era security hardening pass) was written with a manual bootstrap instruction in its own header comment (`kubectl apply -f k8s/argocd/appproject.yaml`, once, before the Application/ApplicationSet). `argocd.tf` was updated at the time to Terraform-manage `application.yaml` and `applicationset-microservices.yaml` via `kubectl_manifest`, but `appproject.yaml` — a third file in the same directory — was never added alongside them. On a long-lived cluster this was invisible: the AppProject, once created by hand, just sits there. It only became a real outage the next time the whole cluster came up from `terraform destroy` + fresh `apply` (today), because nothing ever created it this time.

**Second, related bug caught while fixing the first:** once the AppProject was created (first by hand, to unblock diagnosis; then properly, see Fix below), sync still failed: `resource external-secrets.io:ClusterSecretStore is not permitted in project bookstore; resource storage.k8s.io:StorageClass is not permitted in project bookstore`. `appproject.yaml`'s `clusterResourceWhitelist` only listed `Namespace`, on the stated assumption that Namespace was the only cluster-scoped kind these apps create — wrong: `k8s/base/storageclass/gp3.yaml` (a `StorageClass`) and every service's `external-secret.yaml` (pointing at a `ClusterSecretStore`) are both cluster-scoped too. Same shape of bug as the missing AppProject itself: invisible on a long-lived cluster where these resources already existed and never needed re-creating, only surfacing when ArgoCD has to create them from nothing.

**Fix:** `argocd.tf` gained `resource "kubectl_manifest" "argocd_appproject"` (same pattern as the other two, `depends_on = [module.eks_addons]`), and `argocd_application`/`argocd_applicationset_microservices` now additionally `depends_on = [kubectl_manifest.argocd_appproject]` so ordering is enforced by Terraform's graph, not by hoping someone reads the header comment first. `appproject.yaml`'s `clusterResourceWhitelist` gained `StorageClass` (`storage.k8s.io`) and `ClusterSecretStore` (`external-secrets.io`) alongside `Namespace`. The existing, manually-created AppProject in the live cluster was adopted into Terraform state via a normal `terraform apply` (the `gavinbunney/kubectl` provider's `kubectl_manifest` does a server-side apply, so it updated the live object in place rather than erroring on "already exists").

**A third, unrelated bug found in the same recovery window:** CI's `Lint & Validate` job failed on the same push with `Import in body of module; reorder to top` in `client/src/api/api.test.js` — a `jest.mock("axios", ...)` call had been placed *before* the file's `import` statements to read naturally as "mock, then use the mock," which ESLint's `import/first` rule rejects. Moved the imports above the `jest.mock` call; safe because Jest's `babel-plugin-jest-hoist` moves `jest.mock()` calls above imports at transform time regardless of source order, so the runtime behavior (mock exists before anything imports the real module) is identical either way — only the on-disk ordering changed to satisfy the linter.

**Lesson:** any file added to `k8s/argocd/` needs an explicit `kubectl_manifest` resource in `argocd.tf` and a `depends_on` entry on whatever else references it — a comment saying "apply this manually first" is exactly the kind of instruction that survives fine for months on a cluster that's never rebuilt, then silently fails the first time it's tested for real.

### OBS-060 — ACM cert's wildcard SAN only covered one subdomain level; `api-gateway`'s Ingress never got an ALB

**Symptom:** after OBS-058/059 were resolved, `bookstore-ingress` (host `bookstore.b17facebook.xyz`) got its ALB and hostname fine, but `gateway-ingress` (host `api.bookstore.b17facebook.xyz`) never did — `kubectl describe ingress gateway-ingress -n gateway` showed a repeating event: `Warning FailedBuildModel ... no certificate found for host: api.bookstore.b17facebook.xyz`. `api-gateway`'s ArgoCD Application health stayed `Progressing` indefinitely even though its Deployment was fully healthy (2/2 `Running`, `MinimumReplicasAvailable`) — the AWS Load Balancer Controller simply could never finish reconciling that one Ingress, so its `status.loadBalancer` never populated.

**Root cause:** `ingress-cert.tf`'s `aws_acm_certificate.ingress` requested `subject_alternative_names = ["*.${var.domain}"]` — a wildcard that covers exactly **one** label deep. `bookstore.b17facebook.xyz` (one label under the root domain) matches it; `api.bookstore.b17facebook.xyz` (two labels deep) does not — TLS wildcard certs never match more than one additional label, by design (this is standard X.509 behavior, not an AWS quirk). The AWS Load Balancer Controller's auto-discovery (matching each Ingress's hosts against issued certs, see the file's own header comment) correctly found no match for the gateway's host and refused to build a listener for it, rather than falling back to an unencrypted or mismatched cert.

**Fix:** added a second SAN, `"*.bookstore.${var.domain}"`, to `aws_acm_certificate.ingress` — covers `api.bookstore.<domain>` (and any other future `<x>.bookstore.<domain>` host) without needing an exact-match SAN per service. Since `subject_alternative_names` forces certificate replacement (a new cert with different SANs is a different resource, not an in-place update — `lifecycle { create_before_destroy = true }` on this resource makes that safe, spinning up the replacement before tearing down the original), this needed a full `aws_acm_certificate`/`aws_route53_record.ingress_cert_validation`/`aws_acm_certificate_validation` replacement, re-plan, and apply — a small, contained blast radius (just the cert chain + the ALB-hostname-wait `null_resource` + Route53 alias record refreshes), verified via `terraform plan` before applying.

**Lesson:** a wildcard SAN's "one label deep" limit is easy to forget when a project's Ingress hosts aren't all at the same subdomain depth (`bookstore.<domain>` vs `api.bookstore.<domain>` here) — worth explicitly listing every distinct host *pattern* (not just every host) an Ingress uses when writing the cert's SAN list, rather than assuming one wildcard covers everything under the root domain.

### OBS-061 — `AWS_REGION` was hardcoded in 5+ places, disconnected from `config.env`

**Ask:** "no variables should be hardcoded... everything should be coming from config.env or GitHub Secrets" — a direct follow-up after tonight's DNS/AppProject/ACM incidents, asking for a project-wide sweep rather than one more one-off fix.

**Found, all genuinely hardcoded and disconnected from `config.env`'s `AWS_REGION`:**
- `versions.tf`'s S3 backend block — `region = "us-west-1"` committed directly, never patched by anything (unlike `bucket`/`dynamodb_table`, which `scripts/init-backend.sh` already patched).
- `scripts/init-backend.sh` — took region only as a CLI positional arg (`./scripts/init-backend.sh us-west-1`), no `config.env` awareness at all.
- `k8s/base/secrets/external-secret.yaml` — the shared `ClusterSecretStore`'s `region: us-west-1` field, a real hardcode in a static, git-committed K8s manifest (every service's `ExternalSecret` references this one `ClusterSecretStore` by name, so a wrong region here breaks secret sync cluster-wide).
- `.github/workflows/ci-cd.yml` — `ECR_REGISTRY` had its *own separate* `us-west-1` literal, not even referencing the same file's own `env.AWS_REGION`, so the two could silently drift apart from each other within the same file.

**Fix:**
- `scripts/init-backend.sh` now resolves region as: explicit CLI arg → `config.env`'s `AWS_REGION` → `us-west-1` fallback, and patches it into `versions.tf` the same way `bucket`/`dynamodb_table` already were. `versions.tf`'s committed `region` field is now `""`, matching the other two fields' "account-specific, never committed" pattern instead of being the odd one out.
- `k8s/base/secrets/external-secret.yaml`'s region became a stamped placeholder (`AWS_REGION_HERE`), added to `scripts/configure.py`'s substitution list alongside domain/repo/account — the same mechanism already handling the other 4 files, not a new pattern.
- `ci-cd.yml`'s `ECR_REGISTRY` now references `${{ env.AWS_REGION }}` instead of its own independent literal.
- `docs/DEPLOYMENT.md`'s Step 1 and Step 2 were swapped — `config.env` now has to exist *before* `init-backend.sh` runs, since the latter reads the former's `AWS_REGION`. This was a real ordering dependency the fix introduced, not just a doc tidy-up.

**Scoped deliberately narrower than "every hardcoded value anywhere":** the 3 GitHub Actions workflows' own `AWS_REGION: us-west-1` env-block literals were left as-is by explicit choice — CI can't read `config.env` (gitignored, local-only, by design per `configure.py`'s own docstring: CI gets values from GitHub Secrets), and consolidating those 3 literals into a GitHub Actions repo variable would require the user to configure that in GitHub's own Settings UI, which wasn't asked for. Worth doing later if the account/domain/region trio ever needs to change without a code change.

### OBS-062 — a real email address was hardcoded in an orphaned, unreferenced file at the repo root

**Found during the same sweep:** `cluster-issuer.yaml` at the repo root (not under `k8s/` at all) — a `cert-manager.io/v1` `ClusterIssuer` with a real email hardcoded in its ACME `email` field, and `ingressClassName: nginx` in its HTTP-01 solver — both cert-manager and ingress-nginx were fully removed from this project during OBS-057, so this file predates that migration and was never cleaned up. `grep`-confirmed zero references anywhere in the live deploy flow except `eks_bootstrap.py` (itself already confirmed dead code, zero references anywhere, per `TERRAFORM.md`'s "Known gaps").

**Fix:** deleted outright — dead file, zero consumers, no functional change, one less real personal detail sitting in git history going forward. (Note: deleting the *file* doesn't scrub it from prior git *history* — anyone who cloned before this commit, or who runs `git log -p` on old commits, can still see it. Full history rewrite would be a separate, much bigger and riskier operation, same category of decision as the observability branch's earlier Claude-trailer history rewrite — not attempted here without being asked.)

**Also audited in the same pass, found clean:** `services/api-gateway/__tests__/gateway.test.js` and `services/user-service/__tests__/auth.test.js` both have `JWT_SECRET = "test-secret"` — a literal test fixture, not a real secret, standard practice for deterministic unit tests, correctly *not* sourced from `config.env` or any secret store.

### OBS-063 — Prometheus and Alertmanager had no authentication of their own, reachable from `monitoring_admin_cidr`

**Ask:** a security review flagged this (High severity, 8/10 confidence) — `monitoring_admin_cidr`/`admin_cidr_blocks` default to `0.0.0.0/0` with nothing in the repo overriding it, opening ports 22/3000/9090/9093 on the monitoring EC2's public IP. Grafana (3000) has a real admin password; Prometheus (9090) and Alertmanager (9093) had none at all — anyone in the allowed CIDR could run arbitrary PromQL against full cluster telemetry, read the scrape config (including the internal EKS API endpoint), and silence firing alerts via Alertmanager's API, zero login required.

**Deliberately did NOT touch the network/CIDR side of this** — narrowing `monitoring_admin_cidr` without knowing the real admin IP risks locking out Grafana access too, which wasn't part of what was asked. Fixed the actual gap instead — added real authentication to the two tools that had none, leaving reachability exactly as it was:

- **New:** `modules/eks-addons/monitoring-basic-auth-secret.tf` — a `random_password` + Secrets Manager secret at `/bookstore/monitoring-basic-auth`, same shape as `grafana-secret.tf`'s existing `grafana_admin` secret, wired through `modules/monitoring-ec2` the identical way.
- **`modules/monitoring-ec2/user-data.sh.tftpl`:** fetches the password at boot (same IAM-propagation retry loop as `GRAFANA_PASSWORD`), bcrypt-hashes it via `htpasswd` (both tools' `--web.config.file` format requires bcrypt, not plaintext), and writes `basic_auth_users: {admin: <hash>}` to a `web.yml` for each tool, referenced via a new `--web.config.file` flag on both.
- **A real, easy-to-miss consequence of enabling this:** Prometheus talks to *itself* (a `job_name: 'prometheus'` self-scrape on `localhost:9090`) and to Alertmanager (the `alerting.alertmanagers` delivery block) — both now also need credentials, or Prometheus's own metrics and alert delivery silently break the moment auth turns on. Fixed via `basic_auth: {username: admin, password_file: /etc/prometheus/basic-auth-password}` on both. That `password_file` — not an inline `password:` — matters for a specific reason: `prometheus.yml`'s heredoc is deliberately **quoted** (`<< 'PROM_EOF'`) because its `relabel_configs` use `$1`/`$2`/`$3` regex backreferences that an unquoted, bash-expanding heredoc would silently mangle (bash would try to expand them as positional parameters, most likely to empty strings) — so the password couldn't be interpolated inline into that file the way `alertmanager.yml`'s already-unquoted heredoc does with `$SMTP_*`. Writing it to a separate file first and pointing `password_file` at it sidesteps that entirely, without touching the quoted heredoc's escaping.
- Grafana's own dashboards talk to Prometheus and Alertmanager as datasources (`http://prometheus:9090`, `http://alertmanager:9093`, Docker Compose service-name DNS) — without updating those too, every dashboard panel would start failing with a 401 the moment this shipped. `datasources.yaml`'s heredoc switched from quoted to unquoted (safe here — unlike `prometheus.yml`, this file has no `$`-prefixed content of its own to accidentally expand) and both datasource blocks gained `basicAuth: true` / `secureJsonData.basicAuthPassword`.
- The background dashboard-importer script (`/usr/local/bin/import-grafana-dashboards.sh`) also curls Prometheus directly (`localhost:9090/api/v1/query`) to wait for real scrape data before auto-populating a dashboard template variable — it runs as its own process, so it re-reads the password from the same file the boot script wrote, and both curl calls gained `-u "admin:$PROM_PASS"`.

**Verified:** `terraform validate` clean; every heredoc open/close marker in `user-data.sh.tftpl` re-counted and paired after the edits (15 opens, 15 closes, correct nesting); grepped the whole file for every remaining `:9090`/`:9093` reference to confirm none were missed.

### OBS-064 — any self-registered user could create, modify, or delete the entire book catalog

**Ask:** same security review (Medium severity, 8/10 confidence) — `api-gateway`'s `protectMutations` required only a valid JWT for `/books` writes, and `catalog-service` had zero authorization logic of its own on `POST`/`PUT`/`DELETE /books`. Since `/auth/register` is open and unauthenticated, obtaining a valid JWT cost one HTTP request — register, log in, then `DELETE /books/1..N` to wipe the catalog, or `PUT` to deface it.

**The real tradeoff, worth being explicit about:** actually closing this gap unavoidably changes what a plain registered user can do — before this fix, *every* logged-in user could add/edit/delete books via the UI; after it, only an admin can. There was no way to fix the vulnerability without that behavior change. Resolved it the way that best avoids disrupting the deployer's own workflow: **the very first account ever registered becomes admin automatically**, everyone after that is `customer` by default. Since the DB is fully destroyed as of tonight, the next person to register on a fresh deploy — almost certainly the deployer, testing it — keeps full catalog-management ability exactly as before; only *other* accounts lose it.

**What changed:**
- `k8s/services/user-service/base/schema-init-job.yaml` — `users` table gained `role VARCHAR(20) NOT NULL DEFAULT 'customer'`.
- `services/user-service/app.js` — `/auth/register` counts existing rows first; count `0` → `role = 'admin'`, else `customer`. `role` is now in the JWT payload (`/auth/login`, `/auth/refresh`) and in both endpoints' response bodies, alongside the existing `token`/`refreshToken`.
- `services/api-gateway/app.js` — `verifyJwt` now also sets `x-user-role` from the decoded token (same pattern as the existing `x-user-id`). New `requireAdminForMutation` middleware, chained after `protectMutations` on the `/books` route: GETs pass through untouched, everything else needs `x-user-role === "admin"` or gets a `403`.
- `services/catalog-service/app.js` — a `requireAdmin` middleware on `POST`/`PUT`/`DELETE /books` too, trusting the gateway-set `x-user-role` header the same way `order-service` already trusts `x-user-id` (defense in depth, not the sole boundary — the gateway check above is the real enforcement point).
- Frontend: `AuthContext.jsx` now tracks `role`/`isAdmin` (stored in `localStorage` alongside the existing token/email, refreshed on every silent token refresh same as those). `Books.jsx`'s Delete/Update/Add-book controls gate on `isAdmin`, not `isAuthenticated` — Add-to-Cart deliberately stayed on `isAuthenticated`, since browsing/purchasing was never the vulnerability and shouldn't require admin. New `AdminRoute` component (stricter than the existing `ProtectedRoute`: redirects non-admins away from `/add` and `/update/:id` instead of just requiring login) — `ProtectedRoute` itself was left untouched, since `/cart`/`/checkout`/`/orders` are correctly gated on login alone, not role.

**Not fixed, deliberately:** the underlying `SELECT COUNT(*)` → `INSERT` in `/auth/register` has a real, narrow race window — two concurrent first-ever registrations could theoretically both see `count = 0` and both become admin. Not worth solving with a transaction for what remains a single-operator demo deployment; flagged here rather than silently ignored.

**Follow-up — relaxed on explicit request:** the initial fix gated `POST`/`PUT`/`DELETE /books` on admin uniformly. The user asked for that to be less restrictive: any logged-in user should be able to add a new book, only editing or deleting an *existing* one should stay admin-only (the actual vulnerability this entry describes was about a random user wiping/defacing books they didn't add, not about them contributing new ones). `api-gateway`'s `requireAdminForMutation` renamed to `requireAdminForDestructiveMutation` and now lets `POST` through for any authenticated user (`protectMutations` upstream already required a valid JWT); `catalog-service`'s equivalent middleware (renamed to match) is no longer applied to its own `POST /books`. `PUT`/`DELETE` are unchanged on both — still admin-only. Frontend: `Books.jsx`'s "Add new book" link now gates on `isAuthenticated`, not `isAdmin`; Delete/Update controls are unchanged (`isAdmin`). `App.js`'s `/add` route moved from `AdminRoute` to `ProtectedRoute`; `/update/:id` is unchanged (`AdminRoute`). Verified live against the real cluster: a freshly-registered `customer`-role user got `200` on `POST /books` and `403` on `DELETE /books/1`.

### OBS-065 — orphaned `aws_iam_role.cluster` blocks a re-apply, and `terraform import` can't fix it on a from-scratch attempt

**Symptom:** a `terraform apply` that died partway through a genuinely fresh account (before `module.eks.aws_eks_cluster.this` ever got created) left `bookstore-eks-cluster-role` behind in IAM. The next `apply` failed with `EntityAlreadyExists: Role with name bookstore-eks-cluster-role already exists`.

**Why `make import` doesn't cover this one:** `db-credentials`/`grafana-admin`/`jwt-secret` (Makefile's `import` target) are plain AWS resources, importable regardless of cluster state. The cluster's own IAM role isn't, in this specific scenario: `terraform import` always resolves every configured provider up front, including `kubectl`/`helm`/`kubernetes`, and those are configured from `module.eks.cluster_endpoint`/`cluster_ca_certificate` (see `providers.tf`) — genuinely unresolvable ("Invalid provider configuration ... depends on values that cannot be determined until apply") when the cluster doesn't exist yet, which is exactly when this role is most likely to be orphaned.

**Fix (manual, not automatable the same way as the secrets import):**
```bash
aws iam list-attached-role-policies --role-name bookstore-eks-cluster-role   # confirm empty first
aws iam list-role-policies --role-name bookstore-eks-cluster-role           # confirm empty first
aws iam delete-role --role-name bookstore-eks-cluster-role
terraform apply   # recreates an identical role -- nothing about its identity was worth preserving
```
Safe because a fresh EKS cluster role has no state worth importing — same reasoning `scripts/init-domain.sh` explicitly does NOT apply to the Route53 zone (OBS-058 below), where the identity (nameservers) genuinely matters and recreating would break the registrar delegation again.

### OBS-066 — a slow `helm_release.argocd` install can expire the cluster auth token mid-apply, cascading into unrelated "Unauthorized" errors

**Symptom:** on one `terraform apply` run, `helm_release.argocd` took 34+ minutes to install (vs. its normal ~2 minutes) with no visible cause -- just slower-than-usual EKS/AWS API responses that day. Once it crossed roughly the 15-minute mark, `helm_release.external_secrets` and `helm_release.argo_rollouts` (running concurrently) both started failing with `Unauthorized`, and `helm_release.argocd` itself finished with `Warning: Helm release "" was created but has a failed status`.

**Root cause:** the `helm`/`kubernetes` providers authenticate via `exec { command = "aws", args = ["eks", "get-token", ...] }` (see `providers.tf`) -- a short-lived token fetched once when the provider initializes for that `terraform apply` run, not refreshed mid-run. Any single resource that runs long enough for that token to expire takes every *other* concurrent operation on the same provider down with it, even though they're otherwise unrelated. Checked live via `kubectl get pods -n argocd` and `helm list -A` after the fact: ArgoCD's actual pods had come up healthy well before the token expired -- Helm's own polling connection died from the stale token, not the chart itself failing to install.

**Fix:** none needed in code -- this is AWS API response-time variance, not a bug. Just re-run `terraform apply`; it's idempotent and only recreates what's actually missing/failed (confirmed: a second attempt fixed the `Unauthorized` releases without re-touching anything already healthy). Worth knowing before panicking at an `Unauthorized` error mid-apply: check `kubectl get pods -n argocd` (or whichever release failed) before assuming something is actually broken.

### OBS-067 — a leftover security group blocked VPC deletion for 15-20+ minutes; **originally misattributed to EKS, actually the ALB controller's own shared backend SG**

**Symptom:** `terraform destroy` hung on `module.network.aws_vpc.main: Still destroying...` for 15+ minutes (once even 20, hard-erroring with `DependencyViolation: The vpc '...' has dependencies and cannot be deleted`), with no visibly blocking resource in `describe-network-interfaces`/`describe-route-tables`/`describe-vpc-endpoints` -- all empty.

**Original (wrong) root cause, first written here:** assumed this was EKS's own auto-created "cluster security group," managed entirely by AWS/EKS and unrelated to anything this project's Terraform touches. That guess was never actually verified against evidence.

**Actual root cause, found via CloudTrail (`aws cloudtrail lookup-events --lookup-attributes AttributeKey=ResourceName,AttributeValue=<sg-id>`) after it recurred a third time:** the leftover SG (`k8s-traffic-bookstoreeks-<hash>`) is the **AWS Load Balancer Controller's own shared "backend" security group** -- one per cluster, reused across every Ingress group, tagged `elbv2.k8s.aws/cluster`. Its event history showed `CreateLoadBalancer` and repeated `Authorize/RevokeSecurityGroupIngress` calls from the controller's own IRSA session over the cluster's lifetime, then **nothing** -- no `DeleteSecurityGroup` ever appeared until a human ran one manually. This SG's cleanup is a distinct, slightly-later reconcile step in the controller's own code than clearing an Ingress object's finalizer (which `null_resource.delete_ingress_objects`, OBS-057, already waits for) -- the controller only deletes it once it separately notices zero Ingress groups reference it anymore. `helm_release.aws_lb_controller` (which uninstalls the controller) was destroyed right after `delete_ingress_objects` returned, cutting the controller off before it got to this specific cleanup step. `DeleteVpc` fails as long as ANY non-default security group exists in the VPC, even with zero attached ENIs, so this alone was enough to block it.

**Fix:** `delete_ingress_objects`'s script now polls `aws ec2 describe-security-groups --filters Name=tag:elbv2.k8s.aws/cluster,Values=<cluster>` for up to 20 minutes (120 x 10s) after the `kubectl delete ingress` calls succeed, before returning control to Terraform -- matching the longest this has actually taken to clear on a real cluster. This is the *only* real lever available: `aws_vpc` has no `timeouts` block at all (confirmed -- `terraform validate` rejects one with "Unsupported block type"), so `DeleteVpc` is a single, immediate API call with no Terraform-side retry/backoff to extend as a second safety net. If the SG genuinely still exists by the time `module.network.aws_vpc.main`'s destroy runs, the apply hard-errors on `DependencyViolation` with no further fallback -- still `|| true` on this wait loop, since letting destroy proceed and hard-error with a clear message beats hanging here forever with none.

**Lesson (twice now):** the original write-up here sounded plausible (EKS does auto-manage some things) and was never actually challenged until it recurred a third time and someone asked "but *why*, really?" -- a documented root cause that was never verified against real evidence (CloudTrail, in this case) is a guess wearing a citation's clothes. Second lesson from the same debugging session: an equally plausible-sounding *fix* (add a generous `timeouts` block to the resource that's erroring) can be flatly wrong for reasons specific to that resource type -- worth actually running `terraform validate` against a fix before writing up why it works.

### OBS-068 — default catalog books silently stopped appearing on every fresh apply, since the old monolith was deleted

**Symptom:** a brand-new deploy came up with an empty book catalog -- no error anywhere, ArgoCD `catalog-service` Application `Synced`/`Healthy`, `catalog-schema-init` hook `Succeeded`. Previously, a couple of default books (The Great Gatsby, To Kill a Mockingbird) always appeared on a fresh install.

**Root cause:** `catalog-schema-init`'s SQL was never a direct seed -- it was a one-time MIGRATION, `INSERT INTO catalog_db.books ... SELECT ... FROM test.books`, reading from the old monolith's own database (created and seeded by `k8s/base/database/schema-init-job.yaml`, see OBS-020). That migration was correctly guarded to no-op if `test.books` didn't exist yet (OBS-020/021's own ordering-race concern), so it never hard-failed -- it just silently did nothing. When the old monolith was fully deleted (`chore: delete the old backend monolith`, commit `6e57f01`), `k8s/base/database/schema-init-job.yaml` went with it and `k8s/base/kustomization.yaml` never referenced a `database/` path at all anymore -- confirmed live, the directory doesn't exist on disk. Nothing ever creates `test.books` again, so the migration has been a **permanent, silent no-op** on every apply since that deletion. Every fresh RDS instance since has come up with a real, empty `catalog_db.books` table and zero errors.

**Fix:** `k8s/services/catalog-service/base/schema-init-job.yaml`'s migration block replaced with a direct seed of the original two books (title/desc/price/cover recovered from git history, `git log --all -p -- k8s/database/mysql-init-configmap.yaml`). Guarded on `(SELECT COUNT(*) FROM catalog_db.books) = 0`, not "these two titles are missing" -- this hook runs on every sync (idempotent-by-design, see this file's own top comment), so an admin who deliberately deletes a default book must have it stay deleted, not get silently re-inserted on the next ArgoCD sync. Only fires on a genuinely empty table, i.e. a truly fresh install.

**Lesson:** a migration path that degrades to a silent no-op when its source is missing is exactly the kind of fix that looks safe (no hard failure, no burned `backoffLimit`) but quietly rots the moment the thing it depends on is removed elsewhere in the codebase, with nothing to signal it broke. Worth grepping for what still reads from something before deleting that something's own creator.

### OBS-069 — `helm_release.aws_lb_controller` never actually depended on its own IAM policy, only the role -- controller boots with zero permissions

**Symptom:** `terraform destroy` hung on `null_resource.delete_ingress_objects` past its 600s timeout. Live diagnosis (`kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller`) showed the ingress controller reconcile loop failing on every single attempt: `UnauthorizedOperation: ... is not authorized to perform: ec2:DescribeSecurityGroups because no identity-based policy allows the ec2:DescribeSecurityGroups action`. `aws iam list-role-policies --role-name bookstore-aws-lb-controller` confirmed **zero** policies attached to the role at that point -- reproduced twice, on two independent apply cycles, one of them a clean run with none of the same-session history the first one had.

**Root cause:** `helm_release.aws_lb_controller`'s `serviceAccount.annotations.eks\.amazonaws\.com/role-arn` `set` block references `aws_iam_role.aws_lb_controller.arn` directly, but nothing in the release references `aws_iam_role_policy.aws_lb_controller` (the actual permissions attached to that role) at all. With no attribute reference between the two resources, Terraform has zero ordering constraint and is free to create the Helm release -- and therefore start the controller pods, which begin reconciling immediately -- concurrently with, or even before, the policy attachment finishes. Same shape of gap as the NAT/vpc_cni destroy-ordering bugs fixed earlier this branch (`main.tf`'s `module "eks_addons"` depends_on, and this same file's `vpc_cni` depends_on above), just on the apply side instead of destroy.

**Fix:** added `aws_iam_role_policy.aws_lb_controller` to `helm_release.aws_lb_controller`'s `depends_on` (`modules/eks-addons/aws-load-balancer-controller.tf`), merged with the existing `vpc_cni` entry (Terraform allows only one `depends_on` per resource). The controller's pods now only ever start after the policy is fully attached.

**Live recovery (both times):** `terraform plan -target=module.eks_addons.aws_iam_role_policy.aws_lb_controller` + `apply` to create the missing policy without touching anything else, then `kubectl rollout restart deployment aws-load-balancer-controller -n kube-system` to force an immediate clean reconcile rather than waiting for the next scheduled retry -- both stuck `Ingress` objects (and their finalizers) cleared within 15s of the restart. `terraform destroy` (or `apply`) then proceeds normally on a re-run.

## Related

- [`TERRAFORM.md`](TERRAFORM.md), [`KUBERNETES.md`](KUBERNETES.md), [`CICD.md`](CICD.md), [`DEPLOYMENT.md`](DEPLOYMENT.md)
- [`FUTURE_IMPROVEMENTS.md`](FUTURE_IMPROVEMENTS.md) — OBS-005 and other known gaps that should get fixed properly rather than worked around
