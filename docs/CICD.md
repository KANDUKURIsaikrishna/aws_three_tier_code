# CI/CD

`.github/workflows/ci-cd.yml` — one workflow, five jobs, staged as a real DevSecOps gate rather than a build-and-ship script. Two other workflows exist (`terraform.yml`, `terraform-drift.yml`) but this doc covers the app pipeline.

## Trigger

```yaml
on:
  push:
    branches: [main, improvements, observability]
  pull_request:
    branches: [main, improvements, observability]
```

`observability` was added to this list on this branch specifically so the new `catalog-service` work gets CI coverage while it's being built — it wasn't in the original two-branch list.

## The five jobs

```
secret-scan
    |
    ├── sast ──────┐
    └── validate ──┤
                    v
             build-and-push
                    |
                    v
                 deploy   (main branch only, manual approval gate)
```

### 1. `secret-scan` — Gitleaks

Runs first, on every push and PR, full git history (`fetch-depth: 0`). Blocks everything downstream if it finds anything that looks like a committed secret.

### 2. `sast` — static analysis + tests

Runs backend tests (`cd backend && npm test`), catalog-service tests (`cd services/catalog-service && npm test`), `npm audit --audit-level=high --omit=dev` on both, and Semgrep with `p/nodejs` + `p/owasp-top-ten` + `p/secrets` rulesets (`--error` — any finding fails the job). Node dependency caching is keyed on `cache-dependency-path`, which lists every service's lockfile explicitly:

```yaml
cache-dependency-path: |
  backend/package-lock.json
  client/package-lock.json
  services/catalog-service/package-lock.json
```

**This list has to be updated by hand for every new service** — it's not a glob. Forgetting the entry doesn't break anything, it just means that service's `npm ci` runs uncached on every single CI run instead of hitting the GitHub Actions cache. Easy to miss; happened once already when catalog-service was added (caught in code review, fixed before merge).

### 3. `validate` — lint + manifest validation

ESLint on the frontend (`--max-warnings=0`), then `kubeconform` against every YAML under `k8s/` (excluding `kustomization.yaml` files, which aren't standalone K8s objects) — catches structurally invalid manifests before they ever reach ArgoCD.

### 4. `build-and-push` — the expensive one

```yaml
if: github.ref == 'refs/heads/main' || github.ref == 'refs/heads/improvements' || github.ref == 'refs/heads/observability'
```

Only runs on those three branches (not arbitrary feature branches or PRs) — building and pushing real images on every PR would be wasteful and, more importantly, `iam.tf`'s GitHub OIDC role trust policy only allows `AssumeRoleWithWebIdentity` from `refs/heads/main` and `refs/heads/improvements` in the first place, so this branch condition and the IAM trust policy have to move together. **`observability` needed this job's `if` updated to actually be able to push images from this branch — but the underlying IAM role's trust policy in `iam.tf` was *not* updated to match.** Worth checking before relying on this: if the OIDC role still only trusts `main`/`improvements`, this job will pass its own `if` check and then fail at the "Configure AWS credentials" step with an AWS auth error, not a GitHub Actions error. See [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).

For each image (backend, catalog-service, frontend — same pattern repeated per service, not a matrix/loop):
1. `docker/build-push-action` builds locally (`push: false, load: true`), tagged `<ECR_REGISTRY>/<REPO>:<first-8-chars-of-git-SHA>`
2. `aquasecurity/trivy-action` scans the built image for `CRITICAL`/`HIGH` CVEs, `exit-code: "1"` — **hard fails the build**, images are never pushed with unpatched known-critical CVEs. `ignore-unfixed: true` — a CVE with no available fix doesn't block you forever.
3. On failure, a diagnostic step dumps the SARIF findings as readable text in the CI log (the raw SARIF upload to the Security tab is not easy to read inline)
4. SARIF always uploads to GitHub's Security tab (`if: always()`), regardless of pass/fail
5. Only pushes to ECR if the scan passed

Auth is 100% OIDC — `aws-actions/configure-aws-credentials` exchanges a GitHub-issued OIDC token for temporary AWS credentials via `iam.tf`'s role. No static `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` anywhere in this repo or its secrets.

**Every third-party action is pinned to a full 40-character commit SHA**, not a mutable tag like `@v4`:

```yaml
uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4
```

This is a direct response to real supply-chain incidents (a mutable tag can be silently repointed to malicious code by whoever controls the upstream repo/tag). The human-readable version stays in a trailing comment for maintainability. This was a real Semgrep finding (`github-actions-mutable-action-tag`, 25 occurrences) fixed across all three workflow files — see TROUBLESHOOTING CI-001.

### 5. `deploy` — GitOps handoff, `main` only

```yaml
if: github.ref == 'refs/heads/main'
environment: production   # requires a human reviewer to approve in GitHub before this job runs
```

This is the only job gated behind manual approval, and the only one that runs exclusively on `main` — not `improvements`, not `observability`. Pushing to those other branches gets you full test/scan/build coverage, but never an actual deploy; that's intentional, matches "feature branches get CI, `main` gets CD."

What it actually does — **never calls `kubectl`**:

```bash
cd k8s/overlays/prod
kustomize edit set image bookstore-backend=<registry>/<repo>:<sha>
kustomize edit set image bookstore-frontend=<registry>/<repo>:<sha>
cd ../../services/catalog-service/overlays/prod
kustomize edit set image bookstore-catalog-service=<registry>/<repo>:<sha>

git add k8s/overlays/prod/kustomization.yaml k8s/services/catalog-service/overlays/prod/kustomization.yaml
git diff --staged --quiet && echo "No image tag changes." && exit 0
git commit -m "chore: bump image tags to ${TAG}"
git push
```

It edits `kustomization.yaml`'s image tag and pushes that commit using the default `GITHUB_TOKEN` — pushes made with that token don't trigger another workflow run (GitHub's own loop-prevention), so there's no risk of an infinite CI loop from this commit. ArgoCD picks up the new tag on its next 3-minute poll and does the actual cluster reconcile. This is the entire GitOps contract: CI's job ends at "the desired state in git changed," ArgoCD's job is "make the cluster match git."

## Adding a new service to CI (the pattern, for the next microservice)

1. Add `<SERVICE>_REPO: bookstore-<service>` to the workflow-level `env:` block
2. Add its lockfile to `sast`'s `cache-dependency-path`
3. Add `Install <service> dependencies` / `Run <service> tests` / `npm audit` steps to `sast`
4. Add a build → Trivy scan → diagnostic → SARIF upload → push block to `build-and-push`, following the exact same 5-step pattern as backend/catalog-service
5. Add a `kustomize edit set image` line + its `kustomization.yaml` path to `deploy`'s `git add`

This is copy-paste-and-rename today, not a loop/matrix — deliberately, since the plan-writing process for each service already produces this diff by hand and a matrix would obscure per-service diffs (different Dockerfile contexts, different repo names) for marginal DRY benefit at this scale (currently 3 services; a matrix becomes worth it past 5-6).

## `terraform.yml` / `terraform-drift.yml`

Not detailed here — separate workflows for `terraform plan` on PRs touching `.tf` files and scheduled drift detection, respectively. Same OIDC auth pattern as the app pipeline.

## Related

- [`CICD.md`](CICD.md) *(this file)*
- [`../explaination/DOCKER_EXPLAINED.md`](../explaination/DOCKER_EXPLAINED.md) — what actually happens inside the `build-and-push` job's `docker/build-push-action` steps: the Dockerfiles themselves, stage by stage
- [`TERRAFORM.md`](TERRAFORM.md) — the `iam.tf` OIDC role this pipeline authenticates with
- [`KUBERNETES.md`](KUBERNETES.md) — what ArgoCD does with the image tags this pipeline bumps
- [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) — CI-001 (Semgrep findings) and the observability-branch OIDC trust policy gap
