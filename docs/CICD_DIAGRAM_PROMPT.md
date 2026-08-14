# CI/CD Pipeline Diagram Prompt

A **ready-to-use prompt** for generating an official-AWS-style diagram of this project's CI/CD pipeline — paste the whole file or just the "One-paragraph prompt" section into a diagramming tool or AI image generator. Verified against the actual `.github/workflows/ci-cd.yml` as of 2026-08-14 (6 services build/push/deploy, not the 7 or 3 that earlier versions of this doc/`CICD.md` described — there is no legacy backend image anymore).

**Style target:** same as the architecture diagram — AWS Architecture Icons where a step maps to a real AWS service (CodePipeline-style swimlane look is fine for the CI stages even though this uses GitHub Actions, not CodePipeline, since the actual tool is GitHub Actions, not an AWS service — label it clearly as GitHub Actions, don't substitute an AWS icon for it just to keep the AWS look). Use a top-to-bottom pipeline/swimlane layout with distinct stage boxes, numbered steps, and pass/fail branch points shown as diamond decision nodes. Visually separate the synchronous CI stages from the asynchronous CD handoff — different background tint or an explicit divider line labeled "CI ends here / CD begins here."

---

## One-paragraph prompt (copy this alone if you just need a quick prompt)

> Generate a CI/CD pipeline diagram in the style of an AWS reference architecture pipeline diagram (swimlane layout, numbered steps, clear stage boundaries) for a GitHub Actions workflow named "DevSecOps Pipeline." Start with a developer pushing code to one of three branches (main, improvements, observability) or opening a pull request against them. Stage 1, job "secret-scan," runs Gitleaks against the full git history and blocks everything downstream on any finding. From Secret Scan, branch into two parallel jobs, both gated on it: Stage 2a "sast" (SAST & Dependency Audit — runs npm ci, npm test, and npm audit for 8 separate Node.js projects: 5 backend services plus the client, npm audit at high severity for the 5 services and critical-only for the client, plus one repo-wide Semgrep scan using the nodejs, owasp-top-ten, and secrets rulesets in hard-fail mode) and Stage 2b "validate" (Lint & Validate — ESLint on the frontend with zero tolerance for warnings, plus kubeconform schema validation against every Kubernetes YAML manifest at Kubernetes version 1.31.0). Both must pass before Stage 3, job "build-and-push" (branch-restricted to main/improvements/observability only), which for each of 6 services (catalog-service, user-service, notification-service, order-service, api-gateway, frontend) does: Docker build, then a Trivy container vulnerability scan that hard-fails the pipeline on any unpatched CRITICAL or HIGH severity CVE (unfixed CVEs are explicitly ignored so the pipeline doesn't block forever on something with no available patch), uploads SARIF findings to GitHub's Security tab either way, then pushes the image to a matching Amazon Elastic Container Registry repository only if the scan passed — show all 6 ECR repositories as a fan-out from this stage. Authentication into AWS for this stage uses GitHub's OIDC identity provider exchanged for a temporary AWS IAM role via AWS STS — no static access keys anywhere — draw this as a small OIDC token exchange icon/arrow between GitHub Actions and AWS IAM, landing on a role named bookstore-github-oidc-role. After a successful build-and-push, show a manual approval gate icon (a human reviewer icon) gating the final stage — this is GitHub's built-in "production" Environment protection rule, the only manual step in the entire pipeline. The final stage, job "deploy," runs only on main and observability (not improvements, which gets full build/scan/push but never deploys). It does NOT call Kubernetes directly — it installs Kustomize, edits image tags in six Kubernetes Kustomize overlay directories inside the same git repository, commits that change, and pushes it back to GitHub using the workflow's own token (which deliberately cannot retrigger another workflow run, so there's no infinite loop risk). From there, draw a separate, dashed/asynchronous arrow to an ArgoCD icon (label it clearly as "polls every 3 minutes, not triggered by CI") which detects the git change and performs the actual Kubernetes deployment against Amazon EKS — this is the GitOps boundary, and it should be visually distinct from the synchronous CI stages before it.

---

## Stage-by-stage detail

### Trigger
```
push OR pull_request → branches: [main, improvements, observability]
```
Three long-lived branches trigger the full pipeline; PRs into them do too (minus the deploy stage, which only fires on a direct push to `main` or `observability`).

### Concurrency
```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: false
```
Prevents overlapping `deploy` runs from racing on the same image-tag-bump commit; queues instead of cancelling mid-write.

### Stage 1 — `secret-scan` (Gitleaks)
- Runs first, always, on every trigger. `permissions: {contents: read}`.
- Scans full git history (`fetch-depth: 0`), not just the diff.
- **Hard gate** — nothing downstream runs if this fails.
- Icon: a magnifying-glass-over-lock or similar "scanning" icon; not an AWS service, it's a third-party GitHub Action (`gitleaks/gitleaks-action`).

### Stage 2a — `sast` (parallel with 2b, both `needs: secret-scan`)
Node 22. Runs for **8 separate Node.js projects**, each with its own `npm ci` and `npm test`:
1. `services/catalog-service/`
2. `services/user-service/`
3. `services/notification-service/`
4. `services/order-service/`
5. `services/api-gateway/`
6. `client/` (`CI: true`)

Plus `npm audit --audit-level=high --omit=dev` on each of the 5 backend services, `npm audit --audit-level=critical` on the client only (its build tooling has unfixable high-severity findings, so the bar is critical-only there), and one repo-wide Semgrep scan (`p/nodejs` + `p/owasp-top-ten` + `p/secrets` rulesets, `--error` mode — any finding fails the job). `permissions: {security-events: write, contents: read}`.

### Stage 2b — `validate` (parallel with 2a, `needs: secret-scan`)
- ESLint on `client/` (`--max-warnings=0` — zero tolerance).
- `kubeconform` v0.6.4 against every YAML file under `k8s/` (excluding `kustomization.yaml` files, which aren't standalone Kubernetes objects), `-kubernetes-version 1.31.0` — catches structurally invalid manifests before ArgoCD ever sees them.
- `permissions: {contents: read}`.

### Stage 3 — `build-and-push` (`needs: [sast, validate]`)
**Branch-restricted:** `if: github.ref == 'refs/heads/main' || github.ref == 'refs/heads/improvements' || github.ref == 'refs/heads/observability'` — not arbitrary feature branches or PRs, both to save cost and because the IAM OIDC trust policy only allows those refs to assume the CI role in the first place. `permissions: {id-token: write, contents: read, security-events: write}`.

For **each of 6 services** (catalog-service, user-service, notification-service, order-service, api-gateway, frontend — repeated per-service, not a matrix loop, deliberately, for per-service Dockerfile-context clarity):
1. `docker/build-push-action` builds the image locally (`push: false, load: true`), tagged `<ECR_REGISTRY>/<REPO>:<first-8-chars-of-git-SHA>`
2. Trivy scans for `CRITICAL`/`HIGH` CVEs — **hard fail** on any unpatched finding (`ignore-unfixed: true`, so a CVE with no available fix doesn't block forever)
3. SARIF always uploads to GitHub's Security tab, pass or fail
4. Image pushes to ECR **only if the scan passed**

**Auth:** GitHub OIDC token → AWS STS `AssumeRoleWithWebIdentity` → temporary credentials via the `bookstore-github-oidc-role` IAM role. Zero static AWS keys in the repo or its secrets, anywhere.

**Supply-chain note worth a diagram callout:** every third-party GitHub Action is pinned to a full 40-character commit SHA, not a mutable version tag.

### Approval Gate
- GitHub Environment `production` requires a human reviewer's explicit approval before the `deploy` job runs.
- The **only** manual step in the entire pipeline.
- Draw as a person/reviewer icon blocking the arrow into the final stage.

### Stage 4 — `deploy` (`needs: build-and-push`, GitOps handoff)
**Branch-restricted to `main` and `observability`** — `improvements` gets full build/test/scan/push coverage but never an actual deploy; that's intentional ("feature branches get CI, the long-lived integration/prod branches get CD"). `timeout-minutes: 30`, `environment: production`, `permissions: {id-token: write, contents: write}`.

What it does — **never calls `kubectl` or touches the cluster directly**:
```bash
# for each of the 6 services, in its own overlay directory:
kustomize edit set image bookstore-<service>=<registry>/<repo>:<sha>
git add k8s/.../kustomization.yaml   # (all 6 overlay files)
git commit -m "chore: bump image tags to <sha>"
git push   # using the default GITHUB_TOKEN
```
This commit is pushed with the workflow's own `GITHUB_TOKEN`, which GitHub deliberately doesn't let trigger another workflow run — no infinite CI loop risk from this self-commit. Skips the commit entirely if nothing staged actually changed.

**This is the literal CI/CD boundary.** CI's job ends at "the desired state in git changed." Everything after this point is CD, driven by ArgoCD, not GitHub Actions.

### ArgoCD (GitOps continuous delivery — draw as a distinct, dashed-line stage)
- Polls the git repository **every 3 minutes** — not triggered synchronously by the CI push.
- Two separate ArgoCD-managed objects, both applied by Terraform (`kubectl_manifest`, not manual `kubectl apply`): `application.yaml` (the frontend, path `k8s/overlays/prod`) and `applicationset-microservices.yaml` (an `ApplicationSet` with a list generator covering all 5 microservices, paths `k8s/services/*/overlays/prod`).
- Both are scoped by an `AppProject` named `bookstore` — sources restricted to this one repo, destinations restricted to exactly 6 namespaces, cluster-scoped resources restricted to `Namespace` only. Replaces the previously unrestricted default AppProject.
- On detecting a change: `kustomize build` the overlay, diff against the live cluster state, apply (`prune: true`, `selfHeal: true` — any manual `kubectl` change to a resource ArgoCD owns gets reverted on the next 3-minute reconcile).
- For services with a schema-init `PreSync` hook Job (catalog/user/order/notification), that Job runs automatically before the main sync, no manual DB migration step.

---

## Full pipeline as one diagram (text sketch for layout reference)

```
Developer
   |  git push (main / improvements / observability)
   v
┌─────────────────────────────────────────────────────────────┐
│  GitHub Actions: DevSecOps Pipeline                          │
│                                                                │
│  [1] secret-scan (Gitleaks) ─── fail ──> ✗ pipeline stops     │
│         |                                                      │
│         v (pass)                                               │
│  ┌──────────────────┐   ┌──────────────────────┐              │
│  │ [2a] sast         │   │ [2b] validate         │  (parallel)  │
│  │ npm test/audit ×8 │   │ ESLint, kubeconform   │              │
│  │ + Semgrep         │   │                       │              │
│  └────────┬─────────┘   └──────────┬────────────┘              │
│           └───────────┬────────────┘                           │
│                        v (both pass)                            │
│  [3] build-and-push  (6 services, one at a time)                 │
│       docker build → trivy scan → [fail=✗] → push to ECR        │
│       auth: GitHub OIDC → AWS STS → bookstore-github-oidc-role   │
│                        |                                          │
│                        v                                          │
│              👤 Manual approval (production environment)          │
│                        |                                          │
│                        v  (main / observability only)             │
│  [4] deploy: kustomize edit set image → git commit → git push    │
└───────────────────────┬────────────────────────────────────────┘
                         |  (this is the CI → CD boundary)
                         | (async, not triggered — polled)
                         v
              ┌─────────────────────────┐
              │  ArgoCD (in-cluster)     │
              │  AppProject-scoped       │
              │  polls git every 3 min   │
              │  kustomize build + apply │
              │  prune + selfHeal        │
              └────────────┬─────────────┘
                            v
                  Amazon EKS cluster
                  (6 namespaces updated)
```

## AWS services to render as icons in this diagram

- **AWS Identity and Access Management (IAM)** — the OIDC identity provider + the `bookstore-github-oidc-role`, shown as the auth bridge between GitHub Actions and AWS.
- **Amazon Elastic Container Registry (ECR)** — 6 repositories, the destination of Stage 3.
- **Amazon Elastic Kubernetes Service (EKS)** — the final destination, where ArgoCD actually applies changes.
- Everything else in the pipeline (Gitleaks, Semgrep, ESLint, kubeconform, Trivy, GitHub Actions itself, Kustomize, ArgoCD) is **not an AWS service** — use generic/third-party tool icons or simple labeled boxes, don't force AWS icons onto non-AWS tools just for visual consistency. A small "AWS service" vs. "third-party tool" legend avoids ambiguity.

## Things to get right

- **6 services, not 3 or 7.** The workflow's `env:` block defines `FRONTEND_REPO`, `CATALOG_REPO`, `USER_REPO`, `ORDER_REPO`, `NOTIFICATION_REPO`, `API_GATEWAY_REPO` — all 6 get built, scanned, and pushed on every qualifying run. There is no `BACKEND_REPO` anymore — earlier versions of this prompt (and `docs/CICD.md`'s prose) described a 3-service or 7-service state that no longer exists.
- **`deploy` never runs `kubectl`.** It's pure git — editing YAML files and pushing a commit. Don't draw an arrow from GitHub Actions directly into the Kubernetes cluster; the only thing that touches the cluster is ArgoCD, and only via its own poll loop, scoped by an `AppProject`.
- **The approval gate blocks `deploy` only**, not the build/scan/push stage before it — images already land in ECR before any human clicks approve.
- **`main` and `observability` deploy; `improvements` doesn't.** `improvements` gets everything through Stage 3 (full build/scan/push) but Stage 4 never runs for it — no arrow into ArgoCD from that branch in the diagram.
- **No static AWS credentials anywhere** — every AWS auth step in this pipeline is OIDC-based, temporary-credential-only. If the diagram shows an "AWS Access Key" icon anywhere, that's wrong.
- **This workflow is CI/CD-application only.** Infrastructure changes (Terraform) run through a separate `terraform.yml` workflow with its own plan/apply/drift-detection cycle — don't merge the two pipelines into one diagram, they have different triggers, different approval semantics, and touch different things.

## Related

- [`CICD.md`](CICD.md) — the existing narrative doc (may still describe an older service count, use this prompt's facts instead until that's refreshed)
- [`ARCHITECTURE_DIAGRAM_PROMPT.md`](ARCHITECTURE_DIAGRAM_PROMPT.md) — the companion prompt for the infrastructure/networking diagram
- [`KUBERNETES.md`](KUBERNETES.md) — what ArgoCD actually does once it picks up a change
- `.github/workflows/ci-cd.yml` — the real source of truth this prompt was generated from
