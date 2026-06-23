# Future Context and Development Roadmap

This document captures architectural decisions, known limitations, and planned improvements for the Bookstore application. It is intended to give any future developer — or an AI assistant — immediate context on where the project stands and where it is going.

---

## Current State Summary

The project is a learning/production-reference implementation of a three-tier application on AWS. It has two deployment paths that coexist in the repository:

| Path | Status | Notes |
|---|---|---|
| EC2 / ASG (classic) | **Removed** | Deprecated in favour of EKS path. Modules (asg, bastion, launch_templates, load_balancers) deleted. |
| EKS / Kubernetes | **Active** | Cluster running in us-west-1; all add-ons installed via `eks_bootstrap.py`; ArgoCD GitOps live |

The CI/CD pipeline is DevSecOps-ready: Gitleaks, Semgrep, npm audit, Trivy, tfsec, OIDC auth, and a manual production approval gate are all in place.

---

## Known Limitations and Open Work

### Infrastructure

- **Terraform remote state not fully configured.** The `backend "s3"` block in `main.tf` exists but has empty bucket/table strings. Run `scripts/bootstrap-tf-state.sh us-west-1` and fill in the values before collaborative use.

- **EKS add-ons are manual.** EBS CSI driver, cert-manager, External Secrets Operator, Nginx Ingress, and ArgoCD are installed by `eks_bootstrap.py` — not managed by Terraform. They should eventually be brought under IaC via `helm_release` resources.

- **gp3 StorageClass** is installed by `eks_bootstrap.py` or via `kubectl apply -f gp3-storageclass.yaml`. A `k8s/storageclass/gp3.yaml` manifest would make this declarative.

### Application

- **No integration tests.** The backend has no automated test suite. Any Trivy scan passes on a structurally correct image regardless of application bugs.

- **In-cluster MySQL is not production-safe.** The MySQL StatefulSet is appropriate for local development or single-node clusters. In production, use the RDS instance provisioned by Terraform. The `DB_HOST` configmap value (`mysql-service`) must be changed to the RDS endpoint before applying to a production cluster.

- **No graceful shutdown handling in Node.js backend.** When a pod is terminated, in-flight requests may be dropped. Add `process.on('SIGTERM')` handling to drain connections before exit.

---

## Planned Improvements

### Short Term (next sprint)

1. **Kustomize overlays for dev / staging / prod**
   Add `base/` + per-environment overlays so replica counts, resource limits, and DB host differ per environment — no manual substitution.

2. **Manage EKS add-ons in Terraform**
   Add a `modules/eks-addons/` module using `helm_release` for cert-manager, ESO, and Nginx Ingress. This eliminates the `eks_bootstrap.py` dependency after cluster creation.

3. **Fill in Terraform remote state**
   Run `scripts/bootstrap-tf-state.sh us-west-1` and fill in the `backend "s3"` block in `main.tf`. The script already exists.

4. **Backend graceful shutdown**
   Add `process.on('SIGTERM')` to drain in-flight requests before the Node.js process exits.

### Medium Term

5. **Helm chart**
   Package the k8s manifests as a Helm chart. Easier multi-environment config than Kustomize overlays for complex scenarios.

> **Already completed:** GitOps with ArgoCD is fully live — CI commits new image SHA to `k8s/kustomization.yaml`, ArgoCD syncs within 3 minutes. Image tag substitution uses `kustomize edit set image` (not raw `kubectl set image`).

7. **Helm chart**
   Package the k8s manifests as a Helm chart under `charts/bookstore/`. This makes environment-specific configuration (image tag, replicas, ingress hostname, resource limits) a first-class concern and simplifies multi-environment rollouts.

8. **Observability stack**
   Add Prometheus + Grafana + Loki to the EKS cluster:
   - Prometheus scrapes metrics from Node.js (via `prom-client`) and MySQL
   - Grafana dashboards for request rate, latency, error rate, pod restarts, PVC usage
   - Loki aggregates container logs
   - Alert rules for pod crash-looping, high error rate, DB connection exhaustion

9. **Backend integration tests**
   Add a Jest test suite to the backend that spins up an in-memory SQLite database (or test containers) and covers the CRUD endpoints. Wire the tests into Stage 1 of the CI pipeline before the build step.

10. **Database migration tooling**
    Replace the init SQL in `k8s/database/mysql-init-configmap.yaml` with Flyway or Liquibase migrations. Store versioned migration scripts under `db/migrations/`. The backend pod runs migrations at startup via an init container.

### Long Term

11. **Multi-region active-passive failover**
    Add a second region (e.g., `us-west-2`) with Route 53 health-check-based failover. RDS cross-region read replicas can be promoted in a DR event. The Terraform root module will need a `region` variable-driven multi-workspace strategy.

12. **Service mesh (Istio or AWS App Mesh)**
    Introduce mTLS between pods, fine-grained traffic policies, canary/blue-green deployments via traffic shifting, and distributed tracing (Jaeger or AWS X-Ray) without changing application code.

13. **Canary and blue/green deployments**
    Use Argo Rollouts (or Flagger) to replace the current `kubectl set image` rollout with a progressive delivery strategy: 10% → 25% → 50% → 100% traffic shifting with automated rollback on error-rate breaches.

14. **Cost optimisation**
    - Switch node group to Spot Instances with on-demand fallback using Karpenter
    - Enable RDS storage autoscaling
    - Right-size instance types based on actual CloudWatch metrics
    - Use S3 Intelligent-Tiering for any static asset storage

15. **API Gateway**
    Introduce AWS API Gateway (or Kong) in front of the backend to gain rate limiting, request validation, WAF integration, and API versioning without application changes.

---

## Architecture Decision Records (ADRs)

### ADR-001: Committed to EKS path; EC2/ASG path removed

**Context:** The original project targeted EC2 with Launch Templates and ASGs. EKS was added later and both paths coexisted, causing confusion and extra cost.

**Decision:** EC2/ASG path (launch templates, ASGs, bastion, EC2 IAM role, EC2 ALBs) removed from Terraform and from the repo entirely. The modules `asg/`, `bastion/`, `launch_templates/`, and `load_balancers/` are deleted. EKS is the sole deployment path. Node group runs min 1 / desired 2 / max 4. Route53 public DNS is managed manually (two A-alias records pointing to the Nginx Ingress NLB).

**Consequences:** Simpler, cheaper infrastructure. EC2 module history is in git log if ever needed. Public DNS must be updated manually if the NLB hostname changes after cluster recreate.

---

### ADR-002: In-cluster MySQL StatefulSet vs RDS

**Context:** RDS adds cost and requires network reachability from the EKS cluster. An in-cluster MySQL is free and simple for development.

**Decision:** In-cluster MySQL StatefulSet for local/dev clusters. RDS for production.

**Consequences:** Developers must not apply `k8s/database/` to a production cluster. The `DB_HOST` configmap value must be changed to the RDS endpoint for production deployments. A Kustomize overlay will enforce this separation.

---

### ADR-003: External Secrets Operator over Sealed Secrets

**Context:** The original `db-secret.yaml` stored base64 values in git, which is insecure. Two common alternatives are Bitnami Sealed Secrets (encrypted k8s Secret stored in git) and External Secrets Operator (secret lives only in a cloud vault).

**Decision:** External Secrets Operator pulling from AWS Secrets Manager. We are already committed to AWS; Secrets Manager provides rotation, versioning, and IAM-based access control at no meaningful added complexity.

**Consequences:** ESO must be installed as a cluster add-on (see README). Rotating a password requires only an update to Secrets Manager; the k8s Secret is refreshed within one hour automatically.

---

### ADR-004: GitHub OIDC over static AWS keys

**Context:** Static `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` in GitHub Secrets are a common source of credential leaks (key rotation lag, over-permissioned long-lived keys).

**Decision:** GitHub Actions OIDC token exchange with a scoped IAM role. The role trust policy restricts assumption to the specific repository and branch.

**Consequences:** Requires a one-time IAM OIDC provider setup in AWS. The `AWS_ROLE_ARN` secret holds only the role ARN, not a credential. If the role is misconfigured the pipeline fails with an auth error — never with a leaked key.

---

## Contact and Ownership

| Area | Owner |
|---|---|
| Infrastructure (Terraform) | Platform team |
| Application (React / Node.js) | Application team |
| CI/CD pipeline | DevOps / Platform |
| Secret management | Security / Platform |
