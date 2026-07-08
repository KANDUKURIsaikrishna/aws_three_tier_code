# Cross-Region RDS DR — Design Spec

Date: 2026-07-08
Status: Approved by user, pending write-up into implementation plan

## Problem

`dr.tf` currently only replicates RDS **automated backups** to us-west-2 (`aws_db_instance_automated_backups_replication`, gated by `var.dr_kms_key_id` which defaults to `""` — disabled). There is no live standby database anywhere outside us-west-1. `multi_az = true` gives real automatic failover, but only across AZs *within* us-west-1 — a full region-level primary DB outage has nothing to fail over to. The user wants to validate DR by intentionally cutting off the primary DB and confirming a secondary-region database can pick up the load — that scenario cannot currently succeed, because the capability doesn't exist yet.

## Goal

Add a real cross-region RDS read replica with a documented, scriptable promotion runbook, plus a test suite (Python scripts) that exercises both same-region (Multi-AZ) and cross-region failover and proves recovery.

## Non-goals

- No secondary EKS cluster / compute in us-west-2 (out of scope — separate future work, `secondary_alb_dns` var already reserved for it).
- No fully automatic cross-region failover (AWS does not provide this natively for plain RDS — only Aurora Global Database has managed failover, and migrating engines is explicitly out of scope per the engine-choice decision below).
- No load-balanced multi-region write traffic — this is standby/DR, not active-active.

## Decisions made (in order, each explicitly confirmed by user)

1. **Engine/pattern: standard RDS cross-region read replica**, not Aurora Global Database. Stays on plain MySQL (`db_engine = "mysql"`), no engine migration, no pricing-model change. Trade-off accepted: promotion is a manual/scripted API call, not automatic managed failover — this is the ceiling for plain RDS cross-region DR on AWS.
2. **Secondary-region network: minimal, DB-only.** New VPC in us-west-2 with 2 private subnets across 2 AZs, no NAT/IGW/public subnets. RDS cross-region replication traffic rides AWS's internal backbone, not customer VPC routing — no peering, no internet access needed for the replica itself. Avoids a second NAT Gateway (~$32/mo) for infra that isn't used until there's secondary-region compute.
3. **Cutover mechanism: DNS-based via the existing private Route53 CNAME (`db.bookstore.internal`).** Currently the backend's `DB_HOST` comes straight from the Secrets Manager secret (`aws_db_instance.db.endpoint`, the raw primary endpoint) — the CNAME exists in `modules/route53` but is unused. This changes: `DB_HOST` becomes the static CNAME hostname; failover repoints that CNAME (TTL 100s, already set) instead of touching Secrets Manager. This sidesteps ESO's `refreshInterval: 1h`, which would otherwise add up to an hour of lag to any secret-based cutover.
4. **Scripts in Python**, matching the existing `eks_bootstrap.py` convention: stdlib only (`subprocess`, `json`, `time`, `argparse`), shelling out to `aws`/`kubectl` CLI — no boto3, no requests, no new dependencies.

## Architecture

### New Terraform: secondary-region network (new module, e.g. `modules/network-secondary`)
- `aws_vpc` in us-west-2 (own CIDR block, non-overlapping with primary's `170.20.0.0/16` — e.g. `170.21.0.0/16`)
- 2 private subnets (2 AZs, e.g. us-west-2a/us-west-2b)
- 1 security group: inbound 3306 from nowhere by default (closed until a failover test explicitly opens it, or from a to-be-added secondary EKS node SG once that exists — not now)
- `aws_db_subnet_group` for the replica

### `dr.tf` additions
- `aws_db_instance.secondary_replica`: `provider = aws.secondary`, `replicate_source_db = module.rds.rds_instance_arn`, same `instance_class` as primary, `publicly_accessible = false`, storage/backup settings inherited from source per RDS replica semantics.
- Gated behind new `var.enable_cross_region_replica` (default `false`) — this is a real always-on second instance (~$15-20/mo for db.t3.micro), must be opt-in, not silently forced on for everyone who just runs `terraform apply`.
- Keep the existing automated-backups-replication resource as-is (longer-retention safety net, complements the replica's fast-RTO role).

### `modules/route53` changes
- No structural change to the private zone/CNAME resource itself (already exists, `ttl = 100`) — just document that its target becomes the operational cutover point.

### App config change
- `k8s/base/secrets/external-secret.yaml` / backend config: `DB_HOST` changes from an ESO-sourced Secrets-Manager value to a static value pointing at `db.bookstore.internal` (exact mechanism — ConfigMap vs. hardcoded env — decided in the implementation plan, not here).
- Username/password remain ESO/Secrets-Manager-sourced, unchanged.

### Runbook script: `scripts/dr_failover.py`
Steps, each with clear stdout progress and non-zero exit on failure:
1. `aws rds promote-read-replica --db-instance-identifier <replica-id>`
2. Poll `describe-db-instances` until replica status is `available` (promotion takes a few minutes)
3. Update the Route53 private CNAME to the promoted instance's new endpoint (`aws route53 change-resource-record-sets`)
4. `kubectl rollout restart deployment/backend -n bookstore` (or the Argo Rollout equivalent — check current resource kind, `k8s/base/backend/rollout.yaml` says Argo Rollout, so this needs `kubectl argo rollouts restart backend -n bookstore` instead of a plain Deployment restart)
5. Wait for rollout to complete, print final status

### Test suite (all Python, `scripts/`)
- `test_load_generator.py` — hits `GET /books` on a loop (~1/sec) via `urllib.request`, timestamped pass/fail to stdout and a log file, runs until interrupted or a `--duration` elapses. Used as an observer during the other tests, not a standalone test.
- `test_multi_az_failover.py` — `aws rds reboot-db-instance --force-failover`, starts the load generator alongside, watches for the failover event to complete, reports blip duration from the load generator's log. Expected: brief (seconds), fully automatic, no manual steps.
- `test_cross_region_dr.py` — the actual ask. Steps: start load generator; revoke the RDS security group's inbound 3306 rule from the EKS node SG (safe, instantly reversible — chosen over `stop-db-instance`, which takes several minutes to undo and isn't necessary to prove connectivity loss); confirm requests start failing; run `dr_failover.py`; confirm requests recover; **restore the security group rule** (script always does this in a `finally`, so a failed test run doesn't leave the DB permanently unreachable); print total outage window measured from the load generator's log.
- `test_route53_health_check.py` — separate concern, application-layer only: temporarily deregisters/fails the primary ALB target group's health check, confirms Route53 failover routing shifts to the secondary record. Independent of the DB tests.

## Data flow during a cross-region DR test

```
[load generator] --GET /books--> [backend pod] --DNS lookup db.bookstore.internal--> [CNAME] --> [primary RDS us-west-1]
                                                                                                        |
                                                                            (SG rule revoked — connection refused)
                                                                                                        v
                                                                                              [requests start failing]
                                                                                                        |
                                                                          dr_failover.py: promote replica, repoint CNAME
                                                                                                        v
[load generator] --GET /books--> [backend pod, restarted] --DNS lookup db.bookstore.internal--> [CNAME, new target] --> [promoted replica, us-west-2]
                                                                                              [requests recover]
```

## Error handling

- `dr_failover.py` must be safe to re-run: if the replica is already promoted (no longer a replica), skip promotion and go straight to DNS + restart. Detect via `describe-db-instances` — a promoted instance has no `ReadReplicaSourceDBInstanceIdentifier`.
- `test_cross_region_dr.py` must restore the SG rule even if `dr_failover.py` fails partway — wrap the whole test body in `try/finally`.
- All scripts exit non-zero and print a clear final message on failure; none silently swallow errors (matches this repo's TF-0XX culture of documenting exact symptoms).

## Testing (of the scripts themselves)

These are ops/test scripts, not application code with a unit-test suite — "testing" here means running them against the real (or a throwaway) environment and confirming the documented behavior, same as every other script in `scripts/`. No mocking of AWS — these scripts exist specifically to exercise real AWS behavior.

## Docs to update

- **New:** `docs/disaster-recovery.md` — architecture, runbook, the four test procedures, and an honest RTO/RPO statement (RPO ≈ replication lag, typically seconds; RTO = whatever the test measures in practice, expect low-single-digit minutes for promote+DNS+restart — not instant, not automatic).
- **Update:** `README.md`, `PROJECT_ARCHITECTURE.md`, `TERRAFORM_DOCS.md`, `docs/terraform.md`, `docs/phase-2-architecture.md` — reflect the new secondary-region module and `dr.tf` changes in whatever "current architecture" sections they have.
- **Update:** `FUTURE.md`, `IMPROVEMENTS_PLAN.md`, `docs/phase-2-improvements.md`, `docs/phase-2-future-improvements.md` — if any of these list "cross-region DB replica" or similar as a pending/future item, mark it done and point at `docs/disaster-recovery.md`.
- **Not touched:** `docs/2026-06-26-session-summary.md`, `docs/diagram-prompts*.md` — historical/point-in-time snapshots, not living docs.
- **`docs/phase-2-troubleshooting.md`** gets new `TF-0XX` entries organically during implementation/testing, as real issues are hit — not pre-written speculatively here.

## Open items for the implementation plan (not decided here)

- Exact CIDR for the secondary VPC (`170.21.0.0/16` suggested above, needs confirming against `locals.tf`'s existing allocation to avoid any future overlap if a secondary EKS VPC gets added later).
- Exact mechanism for making `DB_HOST` a static CNAME value in the k8s manifests (ConfigMap key vs. inline env value vs. keeping it in the ExternalSecret but pointed at a Terraform-managed plain SSM/ConfigMap value instead of Secrets Manager).
- Whether `var.enable_cross_region_replica` needs to also gate the secondary network module, or whether the network is cheap enough (no NAT) to always create regardless.
