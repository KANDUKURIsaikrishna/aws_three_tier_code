# CI/CD Pipeline Reference

Bookstore app DevSecOps pipeline. Three GitHub Actions workflows: app pipeline, Terraform pipeline, drift detection.

---

## GitHub Secrets Required

| Secret | Purpose |
|---|---|
| `AWS_ACCOUNT_ID` | Constructs ECR registry URL — `$AWS_ACCOUNT_ID.dkr.ecr.us-west-1.amazonaws.com` |
| `AWS_ROLE_ARN` | OIDC role ARN — no static AWS keys anywhere |
| `API_URL` | Backend API URL injected into React build (`REACT_APP_API_URL`) |
| `SEMGREP_APP_TOKEN` | Semgrep Cloud token (optional — scan runs without it) |

`AWS_ACCOUNT_ID` is never written directly into committed files. `k8s/overlays/prod/kustomization.yaml` uses `000000000000` as placeholder; CI overwrites it with the real value from this secret on every deploy.

---

## Workflow 1 — DevSecOps Pipeline (`ci-cd.yml`)

**Triggers:** push or PR to `main` or `improvements`  
**Runners:** `ubuntu-latest` (GitHub-hosted, unlimited on public repo)

```
push/PR to main or improvements
│
├── [Stage 0] secret-scan          always runs first
│
├── [Stage 1] sast ─────────────── parallel ┐
│                                            │
└── [Stage 2] validate ─────────────────────┘
           both need secret-scan to pass
│
└── [Stage 3] build-and-push       only on push (not PR); needs sast + validate
│
└── [Stage 4] deploy               only on push to main; needs build-and-push; requires prod approval
```

---

### Stage 0 — Secret Scan

**Tool:** Gitleaks via `gitleaks/gitleaks-action@v2`  
**Scope:** Full git history (`fetch-depth: 0`)  
**Fails on:** Any secret, key, or token found anywhere in commit history  
**Blocks:** All other stages — nothing runs if this fails

---

### Stage 1 — SAST & Dependency Audit

| Step | Tool | Fail condition |
|---|---|---|
| Backend unit tests | vitest (`npm test`) | Any test failure |
| Backend dependency audit | `npm audit --audit-level=high --omit=dev` | HIGH or CRITICAL CVE in prod deps |
| Frontend dependency audit | `npm audit --audit-level=critical` | CRITICAL CVE only (react-scripts has unfixable HIGHs) |
| SAST | Semgrep (`p/nodejs`, `p/owasp-top-ten`, `p/secrets`) | Any finding with `--error` |

---

### Stage 2 — Lint & Manifest Validation

| Step | Tool | Fail condition |
|---|---|---|
| Frontend lint | ESLint (`--max-warnings=0`) | Any ESLint warning or error |
| K8s manifest validation | kubeconform v0.6.4 (`-kubernetes-version 1.31.0`) | Any invalid manifest schema |

kubeconform skips `kustomization.yaml` (not a standard k8s resource). Runs on all `k8s/**/*.yaml` files.

---

### Stage 3 — Build → Trivy Scan → Push

Runs only on push (not PR). Requires Stage 1 + Stage 2 to pass.

**Auth:** OIDC via `aws-actions/configure-aws-credentials@v4` — no `AWS_ACCESS_KEY_ID` or `AWS_SECRET_ACCESS_KEY`.

**Image tag:** First 8 characters of git SHA (`${GITHUB_SHA::8}`).

```
For each image (backend, frontend):
  1. docker buildx build --load (no push yet)
       ECR_REGISTRY = secrets.AWS_ACCOUNT_ID.dkr.ecr.us-west-1.amazonaws.com
       tag = <sha8>
  2. trivy scan (CRITICAL,HIGH -- exit-code 1 -- ignore-unfixed)
  3. Upload SARIF to GitHub Security tab
  4. docker push  ← only after clean scan
```

**Docker layer cache:** `type=gha` (GitHub Actions cache) — subsequent builds ~60% faster.

**Frontend build arg:** `REACT_APP_API_URL=${{ secrets.API_URL }}` baked into image at build time.

**SARIF upload:** Trivy findings visible in repo → Security → Code scanning. Always uploads even on failure (for diagnostics).

---

### Stage 4 — GitOps Image Tag Update (Deploy)

Runs only on push to `main`. Requires manual approval via GitHub `production` environment (30-minute timeout).

```bash
# Constructs full ECR URL from secret — account ID never hardcoded
ECR_REGISTRY="${{ secrets.AWS_ACCOUNT_ID }}.dkr.ecr.us-west-1.amazonaws.com"

cd k8s/overlays/prod
kustomize edit set image bookstore-backend=${ECR_REGISTRY}/bookstore-backend:${TAG}
kustomize edit set image bookstore-frontend=${ECR_REGISTRY}/bookstore-frontend:${TAG}

git add k8s/overlays/prod/kustomization.yaml
git diff --staged --quiet && echo "No change, skip." && exit 0
git commit -m "chore: bump image tags to ${TAG}"
git push
```

**Infinite loop protection — two layers:**

| Layer | Mechanism | Why it works |
|---|---|---|
| 1 | Push uses `GITHUB_TOKEN` | GitHub suppresses CI trigger for commits made by `GITHUB_TOKEN` — built-in platform guarantee |
| 2 | `git diff --staged --quiet && exit 0` | No commit if tag unchanged — belt-and-suspenders |

**ArgoCD picks up the commit within 3 minutes and applies to cluster.**

---

## Workflow 2 — Terraform CI/CD (`terraform.yml`)

**Triggers:** push or PR to `main` on `**.tf` file changes or workflow file change  
**Auth:** OIDC (`secrets.AWS_ROLE_ARN`) — same as app pipeline

```
push/PR (**.tf changed)
│
├── Trivy IaC scan (CRITICAL,HIGH = fail)   ← scans .tf files, skips .terraform/
├── terraform fmt -check -recursive
├── terraform init -input=false
├── terraform validate
├── terraform plan -out=tfplan
│       ↓ on PR: posts plan output as PR comment (truncated at 60,000 chars)
│       ↓ on push: continues
└── terraform apply -auto-approve tfplan   ← only on push to main
```

Plan output is posted to the PR as a comment for review before merge. Apply only runs after merge to `main`.

---

## Workflow 3 — Drift Detection (`terraform-drift.yml`)

**Triggers:** Daily cron `0 6 * * *` (06:00 UTC) + manual `workflow_dispatch`

```bash
terraform plan -detailed-exitcode
  exit 0  → "No drift detected"           → job passes
  exit 2  → "DRIFT DETECTED"              → job fails → GitHub alert + notification
  exit 1  → "Plan error (auth/state)"     → job fails → check OIDC role or S3 state
```

Drift = real AWS infrastructure diverged from Terraform state (manual console change, AWS resource modification, etc.).

---

## Security Controls Summary

| Control | Detail |
|---|---|
| No static AWS keys | OIDC only — `role-to-assume` in both workflows |
| No account ID in git base files | `kustomization.yaml` uses `000000000000`; CI overwrites from `secrets.AWS_ACCOUNT_ID` |
| Secret detection | Gitleaks on full git history, every push/PR |
| SAST | Semgrep with nodejs + OWASP Top-10 + secrets rulesets |
| Dependency audit | npm audit on both backend and frontend |
| Container scan | Trivy CRITICAL+HIGH = hard fail before push |
| IaC scan | Trivy on `.tf` files before plan |
| SARIF upload | All Trivy findings visible in GitHub Security tab |
| Action version pinning | `trivy-action@v0.28.0`, not `@master` |
| Minimal job permissions | `contents: read`, `id-token: write`, `security-events: write` — scoped per job |
| Production gate | `environment: production` requires reviewer approval before deploy |
| Loop protection | `GITHUB_TOKEN` push + diff check — no infinite CI loop |
| CODEOWNERS | All paths require `@KANDUKURIsaikrishna` approval on PRs |

---

## Environment Variables (ci-cd.yml)

```yaml
env:
  AWS_REGION:    us-west-1
  ECR_REGISTRY:  ${{ secrets.AWS_ACCOUNT_ID }}.dkr.ecr.us-west-1.amazonaws.com
  BACKEND_REPO:  bookstore-backend
  FRONTEND_REPO: bookstore-frontend
  EKS_CLUSTER:   bookstore-eks
  K8S_NAMESPACE: bookstore
```

---

## Adding a New CI Stage

1. Add job to `.github/workflows/ci-cd.yml`
2. Set `needs: [secret-scan]` minimum — all jobs must depend on secret scan
3. For stages that push artifacts: add `needs: [sast, validate]`
4. For deploy stages: gate behind `if: github.ref == 'refs/heads/main'` and `environment: production`
