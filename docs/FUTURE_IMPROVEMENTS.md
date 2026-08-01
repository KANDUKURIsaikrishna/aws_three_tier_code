# Future Improvements

What's next, in three buckets: finish what's in flight, fix known gaps, then the longer-term roadmap. Written from the actual current state of `observability` (2026-07-31) — not aspirational, and not a copy of the old `FUTURE.md` (which described a pre-EC2-monitoring, pre-microservices state that no longer matches this codebase).

## In flight: the microservices platform

`catalog-service` is done (Plan 1 of 5 — see [Plan 1](superpowers/plans/2026-07-30-catalog-service.md)). Four more plans remain, per the [design spec](superpowers/specs/2026-07-29-microservices-observability-design.md):

1. **`user-service`** — auth/JWT, register/login, own `user_db` schema. Nothing to extract from — this is entirely net-new logic, no existing code to port.
2. **`order-service` + `notification-service`** — place order/list orders, plus a best-effort (not queued) call to notification-service on order placement. Also entirely net-new.
3. **`api-gateway`** — Node/Express + `http-proxy-middleware`, centralized JWT verification, path-routes to all four backend services. **This is also where public traffic actually cuts over** from the old `backend/` — the old monolith gets deleted in this same plan, not before, to avoid a parallel-run state.
4. **Observability extension** — once all 5 services expose real `/metrics`, extend the EC2 Prometheus's scrape config (a `kubernetes_sd_configs` job or a cron-refreshed `file_sd_configs` target list, matching the existing node-exporter pattern) to cover the 5 new namespaces, plus per-service and cross-service Grafana dashboards with PromQL.

Explicitly **not** in scope for this platform, by deliberate design-spec decision (see the spec's Non-goals): service mesh/mTLS, async messaging (SQS), per-service RDS instances, distributed tracing, NetworkPolicy hardening beyond default-deny. These are real gaps, not oversights — see "Longer term" below for where they'd fit if this platform keeps growing.

## Known gaps that should get fixed properly

These aren't "nice to haves" — they're specific, already-identified problems with a clear fix, listed roughly in the order they'd bite you.

1. **CI's OIDC trust policy doesn't cover the `observability` branch.** `iam.tf`'s GitHub OIDC role only trusts `refs/heads/main` and `refs/heads/improvements` — but `.github/workflows/ci-cd.yml`'s `build-and-push` job was updated to run on `observability` too. Right now, that job will pass its `if` check and then fail at AWS auth with no obvious link back to the actual cause. Fix: add the branch to `iam.tf`'s `StringLike` condition — see [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) OBS-005. Do this **before** relying on CI to build/push catalog-service images.

2. **`ApplicationSet`'s `targetRevision: observability` is tracked only by a code comment.** Once the microservices branch merges to `main`, nothing forces `k8s/argocd/applicationset-microservices.yaml` to switch back — and every future service added to the `elements` list inherits whatever `targetRevision` is already there. Worth either a tracked issue, or a cheap CI check that fails if any `k8s/argocd/*.yaml` on `main` references a non-`main` `targetRevision`.

3. **`eks_bootstrap.py`, at the repo root, is very likely dead code.** It predates `modules/eks-addons` — back when cert-manager/ESO/ingress-nginx/ArgoCD were installed by hand via a Python script instead of Terraform `helm_release` resources. Confirm nothing still calls it (check any remaining references in scripts, Makefile, CI, or docs), then delete it. Leaving unused infrastructure-provisioning scripts around invites someone running the wrong one during an incident.

4. **`scripts/bootstrap-tf-state.sh` duplicates `scripts/init-backend.sh`.** The former prints a backend block for manual paste-in; the latter patches `versions.tf` automatically and is what `DEPLOYMENT.md` actually tells people to run. Keep one, probably `init-backend.sh` (it's strictly more automated), and either delete the other or clearly mark it superseded.

5. **`k8s/base/database/` (MySQL StatefulSet/Service/ConfigMap) is dead code sitting on disk.** Not referenced by `k8s/base/kustomization.yaml`, but still present and could confuse a future contributor into thinking in-cluster MySQL is a supported path. Delete it, or move it to a clearly-labeled `examples/` directory if it's meant as reference material for a local-dev-without-RDS scenario.

6. **`k8s/base/monitoring/servicemonitor.yaml` and `prometheus-rules.yaml` are inert CRDs.** Nothing installs the Prometheus Operator that would consume them (Prometheus runs on EC2, scrapes via static/file_sd configs — see [`ARCHITECTURE.md`](ARCHITECTURE.md)). Either actually wire them up (would mean installing the Operator, a real architecture change already rejected once for resource reasons — see TROUBLESHOOTING TF-006) or delete them so they stop implying a capability that doesn't exist.

7. **No graceful shutdown in any Node service.** None of `backend/`, `services/catalog-service/`, or future services handle `SIGTERM` — a pod termination during a rolling update can drop in-flight requests instead of draining them. Small, mechanical fix, same pattern in every service: `process.on('SIGTERM', () => server.close(() => process.exit(0)))`.

8. **`ACM`'s redundant `ignore_changes` warning** ([`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) TF-004) — harmless but permanent noise on every plan/apply. One-line fix, just hasn't been prioritized.

9. **Single NAT gateway, no per-AZ redundancy.** A deliberate cost tradeoff today (see [`TERRAFORM.md`](TERRAFORM.md#module-network)) but a real single point of failure for all private-subnet egress. Worth revisiting once this stops being purely a demo/reference deployment.

10. **The ingress load balancer is a Classic ELB, not an NLB — despite every doc in this project (this session's own docs included) calling it "NLB."** Found via real `terraform apply` failures, see [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) OBS-010. `modules/eks-addons/ingress.tf` never sets the `service.beta.kubernetes.io/aws-load-balancer-type: nlb` annotation and there's no `aws-load-balancer-controller` installed, so EKS's legacy in-tree cloud provider defaults to the oldest, most limited AWS load balancer type (no static IPs, weaker health-check model, generally being phased out in favor of ALB/NLB). Two honest options, not yet decided between: (a) fix the docs to accurately say "Classic ELB" everywhere they currently say "NLB" (`ARCHITECTURE.md`, `DEPLOYMENT.md`, `KUBERNETES.md`, `TERRAFORM.md` all need it), or (b) fix the infrastructure so the NLB this project has always claimed to have actually exists — add the annotation (simplest) or install `aws-load-balancer-controller` (more capable, more to manage). Given this is a "learning reference for AWS 3-tier architecture," (b) is probably the more valuable fix long-term, but changing the LB type means the ingress LB gets recreated (new DNS name, brief downtime) — not a change to make casually on a live stack.

## Test coverage

- `catalog-service`'s tests verify HTTP response shape but (as of the original implementation) didn't assert on what was actually passed to the DB query mock — a params-order regression (e.g. swapping `price`/`desc`) could have shipped silently. Fixed for catalog-service during code review (added `toHaveBeenCalledWith` assertions on POST/PUT), but **apply the same pattern to every future service's tests from the start**, not as a retrofit.
- No integration tests anywhere — every test suite uses a mocked DB query function. Fine for unit-level CRUD logic, but nothing currently exercises a real MySQL connection, real schema constraints, or real ExternalSecret-sourced credentials end-to-end.
- `client/` (the React frontend) has essentially no test coverage beyond the CRA boilerplate `App.test.js`.

## Longer term

Once the 5-service platform is stable and the deferred items above are actually needed (not preemptively):

- **Service mesh (Istio).** mTLS between services, fine-grained `AuthorizationPolicy`, traffic-shifting canaries per service instead of just the gateway. Big enough to warrant its own design spec when it's time — don't bolt it on incrementally.
- **Async messaging (SQS/SNS).** Replace order-service's synchronous best-effort call to notification-service with a real queue. The current sync approach was chosen deliberately to defer this cost, not because it's the intended end state.
- **Per-service RDS isolation.** Today every service shares one RDS instance with per-service schemas/users. Real isolation (separate instances, or at minimum separate parameter groups / separate backup policies) is the natural next step once schema-level isolation stops being enough.
- **Distributed tracing (X-Ray or Jaeger via Istio).** Only useful once there are actually multiple services in a single request path worth tracing — premature before the gateway + at least 2-3 backend services are live.
- **Multi-region active-active**, not just backup replication. Would need a second EKS cluster in `us-west-2` and a real strategy for keeping RDS in sync (cross-region read replica promotion, most likely) — currently `dr.tf` only replicates backups, there's no compute to fail over to.
- **Cost optimization** — Spot instances with Karpenter for the node group, RDS storage autoscaling tuning, right-sizing based on real CloudWatch data once there's real traffic to measure.
- **Database migration tooling** (Flyway/Liquibase) instead of ad-hoc SQL in bootstrap Jobs — worth it once there are enough services/schemas that hand-written bootstrap SQL stops scaling.

## Architecture decisions worth remembering (so they don't get silently re-litigated)

- **EKS over EC2/ASG** — the original project had both paths; EC2/ASG (launch templates, ASGs, bastion) was fully removed. EKS is the only path now.
- **RDS over in-cluster MySQL** — dev/demo convenience of in-cluster MySQL was rejected in favor of RDS everywhere, specifically to avoid a "works on my cluster, breaks in prod" gap. The dead `k8s/base/database/` files are the leftover of that decision (see gap #5 above).
- **External Secrets Operator over Sealed Secrets** — already committed to AWS, Secrets Manager gives rotation/versioning/IAM-scoped access without meaningfully more complexity than Sealed Secrets would.
- **GitHub OIDC over static AWS keys** — no long-lived credentials in GitHub Secrets anywhere in this pipeline. A misconfigured trust policy fails loudly at auth time; a leaked static key fails silently and much worse.
- **Monitoring on EC2, not in-cluster** — not a preference, a resource-constraint decision (see TROUBLESHOOTING TF-006). Revisit only if the node group grows meaningfully past its current size, and even then, weigh the operational simplicity of "monitoring lives outside the thing it's monitoring" before moving back in-cluster.
- **Microservices split is platform-first, not feature-first** — the design spec deliberately scoped this as "5 real services + observability" and explicitly deferred mesh/async/tracing/full-isolation rather than trying to build the complete distributed-systems stack in one pass. Don't accidentally scope-creep a future plan into rebuilding what was deliberately deferred.

## Related

- [`ARCHITECTURE.md`](ARCHITECTURE.md), [`TERRAFORM.md`](TERRAFORM.md), [`KUBERNETES.md`](KUBERNETES.md), [`CICD.md`](CICD.md), [`DEPLOYMENT.md`](DEPLOYMENT.md), [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md)
- [design spec](superpowers/specs/2026-07-29-microservices-observability-design.md) — the authoritative source for what's in/out of scope for the microservices platform
- [Plan 1](superpowers/plans/2026-07-30-catalog-service.md) — catalog-service, the only plan executed so far
