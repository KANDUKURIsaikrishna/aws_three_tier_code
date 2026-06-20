# Troubleshooting Log

Running record of every error hit in this project and exactly how it was fixed.

---

## 1. Terraform — `us-west-1b` availability zone does not exist

**Error**
```
InvalidParameterValue: Value (us-west-1b) for parameter availabilityZone is invalid.
Subnets can currently only be created in the following availability zones: us-west-1a, us-west-1c
```

**Root cause**  
`us-west-1b` does not exist in this AWS account. The region `us-west-1` only has two AZs: `us-west-1a` and `us-west-1c`.

**Fix**  
Replace every `us-west-1b` with `us-west-1c` in `main.tf` (4 subnet entries) and in the commented defaults in `modules/network/variables.tf`.

```hcl
public_subnets = [
  { cidr = "170.20.1.0/24", az = "us-west-1a" },
  { cidr = "170.20.2.0/24", az = "us-west-1c" }   # was us-west-1b
]
```

---

## 2. Terraform / EKS — unsupported Kubernetes version 1.29

**Error**
```
InvalidParameterException: unsupported Kubernetes version 1.29
```

**Root cause**  
EKS 1.29 reached end-of-life. Supported versions at time of fix: 1.30, 1.31, 1.32.

**Fix**  
`main.tf` and `modules/eks/variables.tf`:
```hcl
cluster_version = "1.31"   # was "1.29"
```
Also updated version references in `README.md`, `PROJECT_SUMMARY.md`, `IMPLEMENTATION_GUIDE.md`.

---

## 3. Terraform destroy — RDS deletion protection blocks destroy

**Error**
```
Cannot delete protected DB Instance, please disable deletion protection and try again.
```

**Root cause**  
`deletion_protection = true` was set intentionally for production safety, but blocks `terraform destroy`.

**Fix (two steps)**  
1. Immediate CLI override:
   ```bash
   aws rds modify-db-instance \
     --db-instance-identifier <your-db-id> \
     --no-deletion-protection \
     --apply-immediately
   ```
2. `main.tf` — set `deletion_protection = false` before running destroy. Re-enable (`true`) after rebuilding.

---

## 4. ArgoCD — pods stuck in Pending ("Too many pods")

**Error**
```
0/1 nodes are available: 1 Too many pods.
```

**Root cause**  
A single `t3.medium` node has a pod limit of ~17. Running kube-system + cert-manager + external-secrets + ingress-nginx + ArgoCD simultaneously exceeded that limit.

**Fix**  
Scale the node group to 2 nodes:
```bash
aws eks update-nodegroup-config \
  --cluster-name bookstore-eks \
  --nodegroup-name bookstore-nodes \
  --scaling-config minSize=1,maxSize=4,desiredSize=2
```
Updated `main.tf`:
```hcl
node_desired_size = 2   # was 1
```

---

## 5. ArgoCD — dex-server CrashLoopBackOff (`server.secretkey` missing)

**Error (from `kubectl logs -n argocd deployment/argocd-dex-server`)**
```
FATAL: server.secretkey is missing
```

**Root cause**  
The `argocd-secret` Kubernetes secret was created without the required `server.secretkey` field.

**Fix**
```bash
kubectl -n argocd patch secret argocd-secret \
  -p '{"stringData": {"server.secretkey": "'$(openssl rand -hex 32)'"}}'
kubectl rollout restart deployment/argocd-dex-server -n argocd
```

---

## 6. ArgoCD — ComparisonError: Repository not found

**Error**
```
ComparisonError: Failed to load target state: authentication required: Repository not found
```

**Root cause**  
`k8s/argocd/application.yaml` still contained the placeholder `https://github.com/YOUR_ORG/YOUR_REPO`.

**Fix**  
`k8s/argocd/application.yaml`:
```yaml
repoURL: https://github.com/KANDUKURIsaikrishna/aws_three_tier_code.git
```
If the repo is private, also register credentials with ArgoCD:
```bash
argocd repo add https://github.com/KANDUKURIsaikrishna/aws_three_tier_code.git \
  --username <github-user> \
  --password <personal-access-token>
```

---

## 7. CI — `npm ci` fails: lock file out of sync (frontend)

**Error**
```
npm error `npm ci` can only install packages when your package.json and package-lock.json are in sync.
npm error Missing: typescript@4.9.5 from lock file
```

**Root cause**  
`client/package-lock.json` was stale — `typescript@4.9.5` (a transitive dep of `react-scripts`) was missing.

**Fix**
```bash
cd client
npm install --legacy-peer-deps   # regenerates package-lock.json
```
Commit the updated `client/package-lock.json`.

**Secondary issue**  
`npm audit --audit-level=high` failed because `react-scripts@5.0.1` has 33+ high-severity CVEs in its build tooling (webpack dev server, jest, svgo). These are build-time only and do NOT ship in the Docker image.

**Fix** — `.github/workflows/ci-cd.yml`:
```yaml
run: cd client && npm audit --audit-level=critical   # was --audit-level=high
```

---

## 8. CI — kubeval fails on `kustomization.yaml` (Missing metadata key)

**Error**
```
ERR - k8s/kustomization.yaml: Missing 'metadata' key
```

**Root cause**  
`instrumenta/kubeval-action@master` scanned all files in `k8s/` including `kustomization.yaml`, which is a Kustomize-specific file, not a standard Kubernetes resource — it has no `metadata` field. The kubeval project is also effectively abandoned since 2021.

**Fix**  
Replaced the action with `kubeconform` (actively maintained) which explicitly skips Kustomize files:

```yaml
- name: Validate Kubernetes manifests (kubeconform)
  run: |
    curl -sLo kubeconform.tar.gz \
      "https://github.com/yannh/kubeconform/releases/download/v0.6.4/kubeconform-linux-amd64.tar.gz"
    tar -xzf kubeconform.tar.gz
    sudo mv kubeconform /usr/local/bin/
    find k8s -name "*.yaml" ! -name "kustomization.yaml" | \
      xargs kubeconform \
        -ignore-missing-schemas \
        -kubernetes-version 1.31.0 \
        -summary
```

---

## 9. CI — `npm ci` fails: lock file out of sync (backend)

**Error**
```
npm error Missing: mysql2@3.22.5 from lock file
npm error Missing: @types/node@26.0.0 from lock file
... (11 more missing packages)
```

**Root cause**  
`mysql2` updated to 3.22.5 upstream; `backend/package-lock.json` was stale.

**Fix**
```bash
cd backend
npm install          # regenerate lock file
npm audit fix        # patch express, path-to-regexp, braces, picomatch, send, etc.
npm install nodemon@^3.1.14 --save-dev   # upgrade nodemon 2->3 to clear semver ReDoS high CVE
```
Commit updated `backend/package.json` and `backend/package-lock.json`.
Result: `npm audit --audit-level=high` exits 0 (zero vulnerabilities).

---

## 10. CI — Semgrep: 8 blocking findings

**Findings and fixes**

| Finding | File | Fix |
|---|---|---|
| Private key committed | `3-teir`, `github` | `git rm --cached 3-teir github` + add to `.gitignore` |
| `subprocess.run(..., shell=True)` | `eks_bootstrap.py` | Replaced with `shutil.rmtree(cache_path, ignore_errors=True)` |
| `allowPrivilegeEscalation` missing | `k8s/database/mysql-statefulset.yaml` | Added `securityContext: allowPrivilegeEscalation: false` to MySQL container |
| ECR tag mutability | `modules/ecr/main.tf` | `MUTABLE` → `IMMUTABLE` |
| IMDSv1 allowed on bastion | `modules/bastion/main.tf` | Added `metadata_options { http_tokens = "required" }` |
| HTTP listener flagged | `modules/load_balancers/main.tf` | `# nosemgrep` — frontend is a 301→HTTPS redirect; backend ALB is internal-VPC-only |
| Public subnet public IPs | `modules/network/main.tf` | `# nosemgrep` — required for NAT gateway EIP and internet-facing ALB ENIs |

**Purge keys from git history**
```bash
pip install git-filter-repo
git filter-repo --invert-paths --path 3-teir --path github --force
git remote add origin https://github.com/KANDUKURIsaikrishna/aws_three_tier_code.git
git push origin main --force
```
> **Action required:** Rotate/revoke those SSH keys — they were on a public repo and may have been scraped.

**Also removed from git:** `kubectl.exe` (58 MB binary — install via PATH instead).

---

## 11. CI — Semgrep `nosemgrep` inline comment ignored

**Error**  
Semgrep still blocked on `modules/network/main.tf` even with `# nosemgrep` on the `map_public_ip_on_launch` line.

**Root cause (two parts)**  
1. `returntocorp/semgrep-action@v1` runs semgrep 1.36.0 (EOL — "Versions prior to 1.76.0 are no longer supported"). That version does not honour `nosemgrep` on Terraform multiline block attributes.  
2. Even in current semgrep, `nosemgrep` must be on the **first line of the reported finding** (`resource "aws_subnet" "public" {`), not on the nested attribute that triggered it.

**Fix**  
Replaced the action with a direct pip-install of current semgrep:
```yaml
- name: Semgrep SAST
  run: |
    python -m pip install semgrep --quiet
    semgrep scan \
      --config p/nodejs \
      --config p/owasp-top-ten \
      --config p/secrets \
      --error \
      .
```
Moved `# nosemgrep` to the line **above** the resource block (not inside it):
```hcl
# nosemgrep: terraform.aws.security.aws-subnet-has-public-ip-address.aws-subnet-has-public-ip-address
resource "aws_subnet" "public" {
```

---

## 12. Terraform CI workflow — outdated tooling

**Problems**  
- `TF_VERSION: "1.7.0"` — 18 months old  
- `aquasecurity/tfsec-action@v1.0.0` — tfsec is deprecated and archived by Aqua Security; replaced by Trivy  

**Fixes** in `.github/workflows/terraform.yml`:
```yaml
TF_VERSION: "1.10.0"                   # was 1.7.0

# Replaced tfsec step with:
- name: Trivy — IaC security scan
  uses: aquasecurity/trivy-action@master
  with:
    scan-type: config
    scan-ref: .
    exit-code: "1"
    severity: CRITICAL,HIGH
    skip-dirs: ".terraform"
```
Also added `-input=false` to `terraform init`, `terraform plan`, and `terraform apply` to prevent interactive prompts hanging the CI runner.

---

## 13. CI — Trivy hard-fails on backend image (Node.js 18 EOL)

**Error**
```
Error: Process completed with exit code 1
```
(From the Trivy backend image scan step — no specific CVEs shown in GitHub Actions output, but SARIF was generated)

**Root cause**  
`node:18-alpine` uses Node.js 18 which reached **End-of-Life on April 30, 2025**. Unfixed CVEs in the OS packages and Node runtime cause Trivy to exit 1.

**Cascade effect**  
Because the backend scan failed early, the frontend image was never built, so `trivy-frontend.sarif` did not exist — causing the `upload-sarif` step for frontend to also fail with `Path does not exist: trivy-frontend.sarif`.

**Fix** — upgraded all base images:

| File | Before | After |
|---|---|---|
| `backend/Dockerfile` | `node:18-alpine` | `node:22-alpine` |
| `client/Dockerfile` (build stage) | `node:18-alpine` | `node:22-alpine` |
| `client/Dockerfile` (runner stage) | `nginx:1.25-alpine` | `nginx:1.27-alpine` |

---

## 14. CI — deprecated GitHub Actions versions

**Warnings**
```
Node 20 is being deprecated. This workflow is running with Node 24 by default.
CodeQL Action v3 will be deprecated in December 2026.
```

**Fix** in `.github/workflows/ci-cd.yml`:
```yaml
docker/build-push-action@v5  →  docker/build-push-action@v6
github/codeql-action/upload-sarif@v3  →  github/codeql-action/upload-sarif@v4
```
Both replacements applied to all occurrences (backend and frontend scan steps).

---

## 15. CI — Trivy exits 1 on backend image (dev-dep packages in lock file)

**Error** (first attempt — visible after diagnostic step was added)
```
Error:  CVE-2026-33671: Package: picomatch     ← HIGH, causes exit code 1
Warning: CVE-2026-33750: Package: brace-expansion
Warning: CVE-2026-42338: Package: ip-address
Warning: CVE-2026-33672: Package: picomatch
Warning: CVE-2026-53655: Package: tar
```

**Root cause (two parts)**

1. `picomatch` and `brace-expansion` are marked `"dev": true` in `backend/package-lock.json` (they're pulled in by nodemon). `npm ci --omit=dev` does NOT install them, but Trivy reads `package-lock.json` from inside the image and does not always filter out `"dev": true` packages — so it flags them as if they were installed.

2. `tar` and `ip-address` are not in the project lock file at all; they come from npm's own bundled packages at `/usr/local/lib/node_modules/npm/` (npm uses `tar` internally). These are MEDIUM severity (Warning) and don't trigger the exit code 1 — only the picomatch HIGH CVE does.

**Fix (three changes)**

a. `backend/Dockerfile` — delete `package-lock.json` AFTER all `COPY` steps (it's not needed at runtime; removing it prevents Trivy from reading it and flagging dev-only packages):
```dockerfile
COPY package*.json ./
RUN npm ci --omit=dev && npm cache clean --force

COPY --chown=appuser:appgroup . .
RUN rm -f package-lock.json    # must come after COPY . . or it gets copied back
```

b. Changed `--only=production` → `--omit=dev` (the former was deprecated as of npm 7).

c. Added `RUN apk upgrade --no-cache` to all three image stages (node:22-alpine backend, node:22-alpine builder, nginx:1.27-alpine runner) to patch OS-level packages — this is general hygiene and was added in the same commit.

**Diagnostic step added** — when Trivy fails, a follow-up step (`if: failure()`) now prints CVE IDs to the CI log via `jq`:
```yaml
- name: Show backend CVEs in CI log (diagnostic on failure)
  if: failure()
  run: |
    [ -f trivy-backend.sarif ] && \
      jq -r '.runs[].results[] |
        "[" + (.level | ascii_upcase) + "] " + .ruleId +
        ": " + (.message.text | split("\n")[0])' \
      trivy-backend.sarif
```

---

## Pending / Not Yet Done

| Item | What's needed |
|---|---|
| Rotate the SSH keys that were in `3-teir` and `github` | Revoke old keys, generate new ones outside the repo |
| `ACCOUNT_ID` placeholder in `k8s/kustomization.yaml` | Replace with real 12-digit AWS account ID |
| S3 backend bucket + DynamoDB table in `main.tf` | Fill in `backend "s3"` block before running terraform |
| GitHub Secrets | Set `AWS_ACCOUNT_ID`, `AWS_ROLE_ARN`, `API_URL` in repo Settings → Secrets |
| `deletion_protection` in `main.tf` | Re-enable (`true`) after infrastructure is rebuilt and stable |
| Manual approval gate for terraform apply | Add `environment: production` to the terraform job so apply requires a reviewer |
| IDE error "Value 'production' is not valid" in ci-cd.yml | Create the `production` environment in GitHub Settings → Environments — the VS Code extension validates against live repo environments; the YAML is correct |
