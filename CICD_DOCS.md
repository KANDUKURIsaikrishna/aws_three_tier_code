# CI/CD Pipelines — Deep Dive

This project has two GitHub Actions workflows that together form a complete DevSecOps and infrastructure automation system.

| Workflow | File | Triggers |
|----------|------|----------|
| DevSecOps App Pipeline | `.github/workflows/ci-cd.yml` | Push/PR to `main` or `improvements` |
| Terraform Infrastructure Pipeline | `.github/workflows/terraform.yml` | Push/PR to `main` when `.tf` files change |

---

## App Pipeline — `ci-cd.yml`

### Overview

```
Every push or PR
        │
        ▼
Stage 0 ── Secret Scan (Gitleaks)
        │  fail = stop everything, no other job runs
        │
        ├──────────────────────────────────┐
        ▼                                  ▼
Stage 1 ── SAST & Audit            Stage 2 ── Lint & Validate
  (tests + audit + Semgrep)          (ESLint + kubeconform)
        │                                  │
        └──────────────┬───────────────────┘
                       │  both must pass
                       ▼
               Stage 3 ── Build → Trivy Scan → ECR Push
               (main branch or improvements branch only)
                       │
              [Manual approval gate — GitHub Environment: production]
                       │
                       ▼
               Stage 4 ── GitOps image-tag update
               (main branch only)
                       │
                       ▼
               ArgoCD detects change → deploys to EKS
```

---

### Environment Variables (top-level `env` block)

```yaml
env:
  AWS_REGION:    us-west-1
  ECR_REGISTRY:  ${{ secrets.AWS_ACCOUNT_ID }}.dkr.ecr.us-west-1.amazonaws.com
  BACKEND_REPO:  bookstore-backend
  FRONTEND_REPO: bookstore-frontend
  EKS_CLUSTER:   bookstore-eks
  K8S_NAMESPACE: bookstore
```

These are shared across all jobs without repetition. `ECR_REGISTRY` is constructed from `AWS_ACCOUNT_ID` secret — the account ID is not sensitive but is stored as a secret to avoid hardcoding it and to keep the workflow portable across accounts.

**Required GitHub Secrets:**

| Secret | Where used | Description |
|--------|-----------|-------------|
| `AWS_ACCOUNT_ID` | ECR_REGISTRY env var | Constructs the ECR registry hostname |
| `AWS_ROLE_ARN` | Stage 3 OIDC auth | IAM role to assume for AWS operations |
| `API_URL` | Stage 3 frontend build | Injected as `REACT_APP_API_URL` into the React bundle at build time |
| `SEMGREP_APP_TOKEN` | Stage 1 Semgrep | Optional — only needed for Semgrep Cloud dashboard integration |

---

### Stage 0 — Secret Scan (`secret-scan` job)

```yaml
- name: Checkout (full history for Gitleaks)
  uses: actions/checkout@v4
  with:
    fetch-depth: 0    # full git history, not just latest commit

- name: Gitleaks
  uses: gitleaks/gitleaks-action@v2
```

**What it does:** Scans every commit in the full git history for secrets — AWS keys, API tokens, private keys, passwords, connection strings. Gitleaks uses pattern matching against 150+ known secret formats.

**Why `fetch-depth: 0`?** By default, `actions/checkout` does a shallow clone (depth 1) — only the latest commit. Gitleaks needs the full history because a secret committed 50 commits ago and deleted 49 commits ago is still in git history and still extractable with `git log -p`.

**Why this runs first, before everything else?** If your code contains a secret, you do not want to build an image, scan it, push it to ECR, and deploy it before discovering the secret. Fail fast. Every other job has `needs: secret-scan` (directly or transitively), so if this job fails, nothing else runs.

**What happens on failure:** The pipeline stops. The secret must be removed from git history using `git filter-repo` or BFG Repo Cleaner, then the affected credentials must be revoked at the provider (AWS, GitHub, etc.). Rotating the key in the application is not enough — the key is in public git history.

---

### Stage 1 — SAST and Dependency Audit (`sast` job)

This job runs three distinct security checks plus the test suite.

#### Backend Tests

```yaml
- name: Run backend tests
  run: cd backend && npm test
```

Runs `vitest` with mock database. 6 tests cover all CRUD endpoints (`GET /`, `GET /books`, `POST /books`, `PUT /books/:id`, `DELETE /books/:id`). Tests fail the pipeline before any security scanning — catching logic errors early is cheaper than catching them after a container build.

#### npm audit

```yaml
- name: npm audit — backend
  run: cd backend && npm audit --audit-level=high --omit=dev

- name: npm audit — frontend
  run: cd client && npm audit --audit-level=critical
```

`npm audit` checks every dependency (and transitive dependency) against the npm advisory database for known CVEs.

**Why different levels?** The backend runs on a server — a high-severity vulnerability in a production dependency is a real risk. The frontend uses `react-scripts` as a build tool, which has persistent unfixable high-severity advisories (they are build-time tools, not shipped to users). Using `--audit-level=critical` for the frontend avoids false-positive failures from tooling vulnerabilities that cannot be fixed without ejecting from CRA.

**`--omit=dev`** on backend audit — Dev dependencies (vitest, testing frameworks) don't run in production. Auditing only production dependencies avoids blocking on CVEs in test tools.

#### Semgrep SAST

```yaml
- name: Semgrep SAST
  run: |
    semgrep scan \
      --config p/nodejs \
      --config p/owasp-top-ten \
      --config p/secrets \
      --error \
      .
```

Semgrep is a static analysis tool that matches code patterns against security rules.

| Rule pack | What it finds |
|-----------|--------------|
| `p/nodejs` | Node.js-specific issues: prototype pollution, path traversal, unsafe `eval`, insecure `child_process` usage |
| `p/owasp-top-ten` | SQL injection, XSS, SSRF, insecure deserialization, broken access control |
| `p/secrets` | Hardcoded secrets, API keys, connection strings that Gitleaks might have missed |

`--error` flag makes Semgrep exit with code 1 on any finding, failing the job. Without this flag, Semgrep prints warnings but the pipeline continues.

**Difference from Gitleaks:** Gitleaks looks for strings that look like secrets (pattern matching on values). Semgrep understands code structure (AST-based) and finds vulnerabilities in how code is written — e.g., user input passed directly to a SQL query without parameterization.

---

### Stage 2 — Lint and Validate (`validate` job)

Runs in **parallel** with Stage 1 (both depend only on `secret-scan`, not on each other). This reduces total pipeline time.

#### ESLint

```yaml
- name: ESLint — frontend (zero warnings allowed)
  run: cd client && npx eslint src --max-warnings=0
```

`--max-warnings=0` means any ESLint warning (not just errors) fails the pipeline. This enforces code quality standards strictly. ESLint catches common React mistakes (missing dependency arrays in `useEffect`, incorrect hook usage) and code style issues.

#### kubeconform (Kubernetes manifest validation)

```yaml
- name: Validate Kubernetes manifests (kubeconform)
  run: |
    find k8s -name "*.yaml" ! -name "kustomization.yaml" | \
      xargs kubeconform \
        -ignore-missing-schemas \
        -kubernetes-version 1.31.0 \
        -summary
```

kubeconform validates every Kubernetes YAML file against the Kubernetes 1.31 API schema. It catches mistakes like wrong `apiVersion`, missing required fields, incorrect field types — before any deployment attempt.

**Why exclude `kustomization.yaml`?** `kustomization.yaml` is a Kustomize file, not a native Kubernetes resource. Its schema is not in the Kubernetes API and kubeconform would report it as unknown/invalid.

**`-ignore-missing-schemas`** — Custom resources (CRDs like `Rollout` from Argo Rollouts, `ExternalSecret` from ESO) don't have schemas in the upstream Kubernetes schema registry. Without this flag, kubeconform would fail on every CRD manifest. With it, kubeconform skips unknown resource types instead of failing.

---

### Stage 3 — Build, Scan, Push (`build-and-push` job)

```yaml
if: github.ref == 'refs/heads/main' || github.ref == 'refs/heads/improvements'
```

This job only runs on pushes to `main` or `improvements` branches — **not on pull requests**. This prevents PRs from accidentally pushing unreviewed images to ECR.

#### Image Tagging

```yaml
- name: Derive image tag
  id: tag
  run: echo "tag=${GITHUB_SHA::8}" >> "$GITHUB_OUTPUT"
```

The image tag is the first 8 characters of the git commit SHA (e.g., `a3f82c91`). This approach:
- Is unique per commit — no collisions
- Is traceable — you can find exactly which commit produced any running container
- Is immutable — combined with ECR `IMMUTABLE` tags, once pushed, this exact image is permanent
- Is short — readable in logs and dashboards

#### OIDC Authentication (no static keys)

```yaml
- name: Configure AWS credentials via OIDC
  uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
    aws-region: us-west-1
```

GitHub mints an OIDC JWT for this job. The action exchanges it for temporary AWS credentials by calling `sts:AssumeRoleWithWebIdentity`. The credentials expire after the job completes. No `AWS_ACCESS_KEY_ID` or `AWS_SECRET_ACCESS_KEY` exists anywhere.

#### Build Without Pushing First

```yaml
- name: Build backend image (no push yet)
  uses: docker/build-push-action@v6
  with:
    push:  false
    load:  true    # loads image into local Docker daemon for Trivy
```

The image is built and loaded into the runner's local Docker daemon (`load: true`) but not pushed to ECR yet. This allows Trivy to scan the image before it reaches the registry.

**Docker layer caching (`cache-from: type=gha`)** — GitHub Actions cache stores Docker build layers between runs. If only application code changed (not the base image or dependencies), Docker reuses cached layers and the build takes seconds instead of minutes.

#### Trivy Container Scan

```yaml
- name: Trivy — scan backend
  uses: aquasecurity/trivy-action@master
  with:
    image-ref:      <backend-image>
    format:         sarif
    output:         trivy-backend.sarif
    severity:       CRITICAL,HIGH
    exit-code:      "1"
    ignore-unfixed: true
```

Trivy scans the container image for OS package CVEs (Alpine/Debian packages) and language-level CVEs (npm packages embedded in the image).

**`exit-code: "1"`** — If any CRITICAL or HIGH CVE is found, Trivy exits with code 1, failing the job. The image is never pushed to ECR.

**`ignore-unfixed: true`** — Only fails on CVEs that have a fix available. A CVE with no available fix in any package version cannot be resolved — blocking on it would prevent all deployments indefinitely. With this flag, Trivy warns about unfixed CVEs but doesn't fail the build.

**SARIF output and GitHub Security tab** — Trivy writes results in SARIF format (a standard for security tool output). The `github/codeql-action/upload-sarif` step uploads this to GitHub's Security tab, where CVEs appear as code scanning alerts with severity, CVE ID, and affected package details.

**Diagnostic step on failure:**
```yaml
- name: Show backend CVEs in CI log
  if: failure()
  run: |
    jq -r '.runs[].results[] | "[" + (.level | ascii_upcase) + "] " + .ruleId + ": " + (.message.text | split("\n")[0])' trivy-backend.sarif
```
If Trivy fails, this step parses the SARIF file and prints a human-readable list of CVEs directly in the CI log. Without this, you'd have to download the SARIF file or open the GitHub Security tab to see what failed.

#### Push Only After Passing Scan

```yaml
- name: Push backend image
  run: docker push ${{ env.ECR_REGISTRY }}/${{ env.BACKEND_REPO }}:${{ steps.tag.outputs.tag }}
```

Image push only runs if the Trivy scan step succeeded. The same pattern repeats for the frontend image. The `REACT_APP_API_URL` build arg is injected at this point:

```yaml
- name: Build frontend image
  with:
    build-args: REACT_APP_API_URL=${{ secrets.API_URL }}
```

This bakes the backend API URL (`https://api.bookstore.b17facebook.xyz`) into the React bundle at build time. The React app running in users' browsers calls this URL directly — not through any server-side proxy.

---

### Manual Approval Gate

```yaml
deploy:
  environment: production
```

The `production` environment in GitHub requires a designated reviewer to manually approve before this job starts. Configuration:
- Go to repo Settings → Environments → production
- Add required reviewers (your GitHub username)
- Optionally set a deployment timeout

After Stage 3 completes, the pipeline pauses. GitHub sends a notification (email or Slack) to reviewers. A reviewer inspects the changes and clicks "Approve and deploy" in the GitHub Actions UI. Only then does Stage 4 run.

**Why a manual gate?** The automatic stages verify the image is safe (no leaked secrets, no known CVEs, no audit failures). But automated scans cannot verify that the application behavior is correct — only a human can confirm that "this feature works as expected and is safe to deploy to production."

---

### Stage 4 — GitOps Image Update (`deploy` job)

```yaml
if: github.ref == 'refs/heads/main'
```

Stage 4 only runs on pushes to `main` — not `improvements`. Deployments go to production only from the main branch.

#### How GitOps Deployment Works

```yaml
- name: Update image tags in kustomization.yaml
  run: |
    cd k8s/overlays/prod
    kustomize edit set image \
      bookstore-backend=${{ env.ECR_REGISTRY }}/bookstore-backend:${TAG}
    kustomize edit set image \
      bookstore-frontend=${{ env.ECR_REGISTRY }}/bookstore-frontend:${TAG}

- name: Commit and push updated image tags
  run: |
    git add k8s/overlays/prod/kustomization.yaml
    git diff --staged --quiet && exit 0   # skip if no change
    git commit -m "chore: bump image tags to ${TAG}"
    git push
```

**Why commit to the repo instead of running `kubectl set image`?**

`kubectl set image` applies the change directly to the cluster. It works, but:
- The change is not recorded in git — nobody knows what image is running
- ArgoCD would immediately revert it (`selfHeal: true`)
- There's no audit trail
- Rolling back requires running another `kubectl` command manually

By committing the new image tag to `kustomization.yaml`:
- Git history records every deployment: who approved it, when, what changed
- ArgoCD picks up the change in ~3 minutes and applies it
- Rolling back means reverting the git commit (a standard git operation)
- The cluster state is always derivable from the git state

**Why `GITHUB_TOKEN` instead of a personal access token?**
```yaml
- uses: actions/checkout@v4
  with:
    token: ${{ secrets.GITHUB_TOKEN }}
```
Pushes made with `GITHUB_TOKEN` do NOT trigger new workflow runs. This prevents an infinite loop: Stage 4 pushes a commit → that commit would trigger Stage 0-4 again → Stage 4 pushes another commit → infinite loop. With `GITHUB_TOKEN`, GitHub explicitly breaks this cycle.

**What ArgoCD does after the push:**
1. ArgoCD polls the repo every ~3 minutes
2. Detects that `k8s/overlays/prod/kustomization.yaml` changed
3. Runs `kustomize build k8s/overlays/prod/` to get the desired manifests
4. Compares desired state with current cluster state
5. Applies only the diff — in this case, updates the image reference in the backend Rollout and frontend Deployment
6. Argo Rollouts controller picks up the Rollout change and executes the canary strategy: 10% → 30s → 50% → 30s → 100%

---

## Terraform Pipeline — `terraform.yml`

### Trigger

```yaml
on:
  push:
    branches: [main]
    paths:
      - "**.tf"
      - ".github/workflows/terraform.yml"
  pull_request:
    branches: [main]
    paths:
      - "**.tf"
```

Only fires when `.tf` files change (or the workflow file itself changes). A commit that only touches `backend/app.js` does not trigger Terraform — avoids unnecessary plan runs and AWS API calls.

---

### Steps

#### 1. OIDC Authentication

Same mechanism as the app pipeline. The same `bookstore-github-oidc-role` is assumed. This role needs additional permissions beyond ECR push — specifically `eks:*`, `ec2:*`, `rds:*`, `iam:*` etc. for Terraform to create infrastructure. In this project the role policy grants `ecr:*` only (as defined in `iam.tf`) — for full Terraform apply you'd need to expand it. For demo purposes, you can run `terraform apply` locally with your own AWS credentials.

#### 2. Trivy IaC Scan (replaces tfsec)

```yaml
- name: Trivy — IaC security scan
  uses: aquasecurity/trivy-action@master
  with:
    scan-type: config
    scan-ref: .
    exit-code: "1"
    severity: CRITICAL,HIGH
    skip-dirs: ".terraform"
```

Trivy in `config` mode scans Terraform files for misconfigurations — same engine as the container scan but for IaC. It checks for:
- S3 buckets without encryption or versioning
- Security groups allowing `0.0.0.0/0` on sensitive ports
- RDS without encryption or deletion protection
- EKS clusters without control plane logging enabled
- IAM policies with wildcard permissions

`skip-dirs: ".terraform"` — The `.terraform/` directory contains provider binaries and cached modules. Scanning it is unnecessary and slow.

**Why Trivy instead of tfsec?** tfsec was acquired by Aqua Security (the company behind Trivy) and is now integrated into Trivy. Trivy covers both IaC and container scanning with a single tool.

#### 3. Terraform Format Check

```yaml
- name: Terraform Format Check
  run: terraform fmt -check -recursive
```

`terraform fmt -check` verifies all `.tf` files are properly formatted according to canonical HCL style. It exits non-zero if any file would be changed by formatting. This enforces consistent style without running a separate linter. Fix locally with `terraform fmt -recursive`.

#### 4. Terraform Init

```yaml
- name: Terraform Init
  run: terraform init -input=false
```

Downloads providers (`aws ~> 5.0`, `helm ~> 2.0`) and initializes the S3 backend. `-input=false` prevents Terraform from prompting for input interactively (which would hang the CI runner forever).

#### 5. Terraform Validate

```yaml
- name: Terraform Validate
  run: terraform validate
```

Validates the configuration syntax and internal consistency — references between modules, output names, variable types. Runs without making AWS API calls. Catches missing required variables, type mismatches, and undefined references.

#### 6. Terraform Plan

```yaml
- name: Terraform Plan
  id: plan
  run: terraform plan -out=tfplan -input=false -no-color 2>&1 | tee plan_output.txt
  continue-on-error: true
```

`-out=tfplan` saves the plan to a binary file. The exact plan file is used in the apply step — this guarantees that what was reviewed is exactly what gets applied (no drift between plan and apply).

`-no-color` strips ANSI color codes because they render as garbled text in GitHub PR comments.

`2>&1 | tee plan_output.txt` — Terraform writes some output to stderr. Redirecting stderr to stdout (`2>&1`) and piping to `tee` captures everything to a file while still showing it in the CI log.

`continue-on-error: true` — If the plan fails (e.g., AWS API error, invalid configuration), the pipeline continues to the next step to post the error as a PR comment. Then a separate step fails the pipeline explicitly:
```yaml
- name: Fail if plan errored
  if: steps.plan.outcome == 'failure'
  run: exit 1
```

#### 7. PR Comment with Plan

```yaml
- name: Comment plan on PR
  if: github.event_name == 'pull_request'
  uses: actions/github-script@v7
  with:
    script: |
      const plan = fs.readFileSync('plan_output.txt', 'utf8').slice(0, 60000);
      github.rest.issues.createComment({ body: `#### Terraform Plan\n\`\`\`hcl\n${plan}\n\`\`\`` });
```

On pull requests, the plan output is posted as a PR comment. Reviewers can see exactly what infrastructure changes will happen when the PR is merged — without needing Terraform installed locally or AWS access.

`.slice(0, 60000)` — GitHub PR comment body is limited. Very large plans are truncated to avoid API errors.

#### 8. Terraform Apply

```yaml
- name: Terraform Apply
  if: github.ref == 'refs/heads/main' && github.event_name == 'push'
  run: terraform apply -auto-approve -input=false tfplan
```

Applies the saved plan file from step 6. Only runs on push to `main` (not on PRs). `-auto-approve` is safe here because a human already reviewed the plan in the PR comment before merging.

**Why apply the saved plan file and not re-plan?** If you run `terraform plan` and then `terraform apply` (without the plan file), Terraform re-plans at apply time. Between plan and apply, someone else might have changed AWS resources manually — the apply could include unintended changes. Using `-out=tfplan` and `apply tfplan` guarantees the exact plan that was reviewed is what gets applied.

---

## Security Architecture Summary

| Threat | Mitigation |
|--------|-----------|
| Secrets in code | Gitleaks scans full git history on every push |
| Vulnerable dependencies | npm audit (high/critical) on backend, critical on frontend |
| Code-level vulnerabilities | Semgrep with Node.js + OWASP Top-10 rules |
| Vulnerable container images | Trivy blocks ECR push on CRITICAL/HIGH fixable CVEs |
| IaC misconfigurations | Trivy in config mode on every Terraform change |
| Malformed k8s manifests | kubeconform validates against Kubernetes 1.31 schema |
| Static AWS credentials | GitHub OIDC — short-lived tokens only, zero static keys |
| Unauthorized deployments | Manual approval gate via GitHub Environment |
| Ad-hoc kubectl drift | ArgoCD selfHeal reverts any manual changes |
| Broken code deployed | vitest test suite must pass before any build step |
| Unknown production state | GitOps — git repo is always the source of truth |

---

## Pipeline Execution Times (approximate)

| Stage | Time |
|-------|------|
| Secret scan (Gitleaks) | ~30 seconds |
| SAST + audit (with npm cache hit) | ~2–3 minutes |
| Lint + validate (with npm cache hit) | ~1–2 minutes |
| Build backend + Trivy scan | ~3–5 minutes |
| Build frontend + Trivy scan | ~4–6 minutes |
| Manual approval | depends on reviewer |
| GitOps image update commit | ~30 seconds |
| ArgoCD reconciliation | ~3 minutes |
| **Total (automated, no approval wait)** | **~12–18 minutes** |
