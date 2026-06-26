# CI/CD Pipeline — Complete Guide for Beginners

This document explains every stage of the automated pipeline that takes your code from a `git push` all the way to a running application on AWS. No prior DevOps knowledge assumed.

---

## What is a CI/CD Pipeline?

Imagine you're working in a team. Every time someone writes new code, you need to:

1. Make sure nobody accidentally committed a password or API key
2. Check the code doesn't have security vulnerabilities
3. Package the app into a shippable format
4. Check the package for known security issues
5. Send it to production

Doing all of this manually every single time is slow and error-prone. A **CI/CD pipeline** automates all of it. Every time someone pushes code to GitHub, the pipeline runs automatically, checks everything, and deploys — without human intervention (except for a final approval gate before production).

- **CI** = Continuous Integration — automatically test and validate code on every push
- **CD** = Continuous Deployment — automatically deliver validated code to production

---

## Two Pipelines in This Project

This project has **two separate pipelines** that run independently:

| Pipeline | File | When it runs | What it does |
|----------|------|-------------|--------------|
| **App Pipeline** | `.github/workflows/ci-cd.yml` | Every push/PR to `main` | Builds, scans, deploys the Node.js + React app |
| **Infrastructure Pipeline** | `.github/workflows/terraform.yml` | Only when `.tf` files change | Creates/updates AWS cloud resources |

They run independently — pushing app code doesn't rebuild cloud infrastructure, and changing Terraform doesn't rebuild Docker images.

---

## How Authentication Works (No Passwords Stored)

Before explaining the stages, it's important to understand **how the pipeline authenticates with AWS** without storing any passwords.

Traditional approach (bad): Store `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` in GitHub Secrets. These are long-lived keys — if leaked, an attacker has permanent access.

This project uses **OIDC (OpenID Connect)** instead:

```
GitHub Actions → "Here is a one-time token proving I am repo X, running on branch main"
AWS IAM       → "I trust GitHub. Token verified. Here are temporary 15-minute credentials."
GitHub Actions → Uses temporary credentials → Credentials expire automatically
```

No static passwords exist anywhere. Even if someone gained access to the pipeline logs, there's nothing to steal — the credentials are already expired.

---

## Pipeline 1: App Pipeline (ci-cd.yml)

This pipeline has **4 stages** that run in sequence. Each stage must pass before the next one starts.

```
[Push to main]
      │
      ▼
┌─────────────────┐
│  Stage 0        │  Secret Scan
│  Gitleaks       │  Did anyone commit a password?
└────────┬────────┘
         │ PASS
         ▼
┌─────────────────┐  ┌─────────────────┐
│  Stage 1        │  │  Stage 2        │  (run in parallel)
│  SAST           │  │  Lint/Validate  │
│  Security scan  │  │  Code quality   │
└────────┬────────┘  └────────┬────────┘
         │ PASS                │ PASS
         └─────────┬───────────┘
                   ▼
         ┌─────────────────┐
         │  Stage 3        │
         │  Build → Scan   │
         │  → Push to ECR  │
         └────────┬────────┘
                  │ PASS + Manual Approval
                  ▼
         ┌─────────────────┐
         │  Stage 4        │
         │  Deploy (GitOps)│
         │  ArgoCD syncs   │
         └─────────────────┘
```

---

### Stage 0 — Secret Detection (Gitleaks)

**What it does:** Scans every single commit in the repository's git history looking for secrets — API keys, passwords, AWS credentials, private keys, tokens.

**Why this matters:** Developers sometimes accidentally type a password directly into code (`password = "MySecret123"`). Once that's pushed to a public GitHub repository, search engines and bots index it within minutes. Even if you delete the file in the next commit, the secret is still visible in git history. This stage catches it before it reaches the public repo.

**Tool used:** [Gitleaks](https://github.com/gitleaks/gitleaks) — an open source scanner that knows patterns for 100+ types of secrets (AWS keys, GitHub tokens, Stripe keys, etc.)

**What triggers failure:** Any pattern matching a known secret format found in any commit.

**What happens next:** If this fails, ALL other stages are blocked. Nothing proceeds until the secret is removed from history.

```yaml
- name: Gitleaks — detect secrets across git history
  uses: gitleaks/gitleaks-action@v2
```

---

### Stage 1 — SAST & Dependency Audit

**SAST** = Static Application Security Testing. "Static" means the code is analyzed without running it.

This stage has three checks:

#### Check 1: npm audit

Every Node.js project uses external packages (libraries). These packages sometimes have known security vulnerabilities — called **CVEs** (Common Vulnerabilities and Exposures). The CVE database is public and constantly updated.

```
npm audit → checks your packages against the CVE database → fails if HIGH or CRITICAL vulnerabilities found
```

This runs separately for both the backend (`/backend`) and frontend (`/client`).

**Example:** If your project uses an old version of `express` that has a known SQL injection vulnerability, `npm audit` catches it.

#### Check 2: Semgrep SAST

Semgrep reads your actual JavaScript/Node.js code and applies hundreds of security rules. Unlike `npm audit` (which only checks package versions), Semgrep catches **how you wrote your code**.

Rules applied:
- **p/nodejs** — Node.js specific vulnerabilities (unvalidated input, dangerous functions)
- **p/owasp-top-ten** — The 10 most critical web security risks (injection, broken auth, etc.)
- **p/secrets** — Hardcoded credentials in source code

**Example:** If your code does `db.query("SELECT * FROM users WHERE id = " + req.params.id)` (SQL injection risk), Semgrep flags it.

**Why both npm audit AND Semgrep?**
- `npm audit` → "Is this library version known to be dangerous?"
- `Semgrep` → "Are you using safe libraries in an unsafe way?"

---

### Stage 2 — Lint & Manifest Validation

This stage runs **in parallel** with Stage 1 (both start at the same time), which saves time.

#### Check 1: ESLint

ESLint checks JavaScript/React code for style issues, potential bugs, and anti-patterns. The pipeline uses `--max-warnings=0` which means **zero tolerance** — even a warning fails the build.

This enforces consistent code quality across the team. No more "it works on my machine."

#### Check 2: Kubeconform (Kubernetes manifest validation)

The `k8s/` folder contains YAML files that describe how to run the application on Kubernetes. These files have a strict schema — Kubernetes will reject malformed files.

**Kubeconform** validates every YAML file in `k8s/` against the Kubernetes 1.31 schema before anything is deployed. This catches typos and structural errors early.

**Example failure it prevents:** You write `replicase: 2` instead of `replicas: 2`. Without validation, Kubernetes silently ignores unknown fields, and you'd wonder why scaling doesn't work.

---

### Stage 3 — Build → Container Scan → Push

This is the most important stage. It only runs on pushes to `main` (not on pull requests).

#### What is a Docker container?

Think of it like a shipping container. Instead of shipping just your app code, you package:
- Your app code
- The exact version of Node.js it needs
- All the system libraries it depends on
- Configuration

This container runs identically everywhere — developer laptop, CI server, production AWS. No more "it works on my machine" problems.

#### Step 1: Create a unique image tag

```bash
tag = first 8 characters of git commit SHA
# Example: commit abc123def456 → tag = abc123de
```

Every build gets a unique tag tied to the exact commit that produced it. This means you can always trace a running container back to the exact line of code it came from.

#### Step 2: Build the image (no push yet)

Docker builds two images:
- `bookstore-backend` — the Node.js/Express API server
- `bookstore-frontend` — the React app served via Nginx

The image is built locally on the CI runner but **not yet pushed to AWS**. This is intentional.

#### Step 3: Trivy security scan

**Trivy** scans the built Docker image for known CVEs in:
- The operating system packages inside the container
- The language runtime (Node.js version)
- The npm packages bundled into the image

```
CRITICAL or HIGH vulnerability found → pipeline FAILS → image is NOT pushed
```

This is the critical security gate. An image with known critical vulnerabilities **never reaches production**. Ever.

The scan results are uploaded to GitHub's Security tab in SARIF format, so you can browse vulnerabilities in a nice UI without digging through logs.

#### Step 4: Push to ECR

Only if Trivy passes does the image get pushed to **ECR** (Elastic Container Registry) — AWS's private Docker image registry. Think of ECR like a private Docker Hub that only your AWS account can pull from.

The image is now available at:
```
YOUR_AWS_ACCOUNT_ID.dkr.ecr.us-west-1.amazonaws.com/bookstore-backend:abc123de
```

---

### Stage 4 — Deploy via GitOps

**What is GitOps?**

Traditional deployment: CI pipeline runs `kubectl apply` and directly tells Kubernetes "deploy this."

GitOps approach: CI pipeline **commits a file change to git**. A separate tool (ArgoCD) watches the git repo and applies whatever it sees there to the cluster.

```
CI pipeline commits  →  ArgoCD detects change  →  ArgoCD applies to cluster
```

Why GitOps?
- Git becomes the **single source of truth** for what's running in production
- Every deployment is a git commit — full audit trail
- Rolling back = reverting a commit
- No direct cluster access needed from CI

#### What this stage does

1. Installs `kustomize` (a Kubernetes config management tool)
2. Updates `k8s/kustomization.yaml` with the new image tag from Stage 3:

```yaml
# Before:
images:
- name: bookstore-backend
  newName: YOUR_AWS_ACCOUNT_ID.dkr.ecr.us-west-1.amazonaws.com/bookstore-backend
  newTag: abc123de   # ← CI updates this

# After (new commit):
  newTag: def456gh   # ← new tag from this build
```

3. Commits and pushes that change using `GITHUB_TOKEN`

> **Important:** GitHub Actions pipelines do NOT re-trigger when `GITHUB_TOKEN` pushes a commit. This prevents an infinite loop (deploy commits → triggers build → triggers deploy → ...).

#### Manual Approval Gate

This stage has:
```yaml
environment: production
```

This means GitHub pauses the pipeline and **waits for a human reviewer to click "Approve"** before proceeding. This gives your team a last checkpoint to review what's being deployed.

#### ArgoCD takes over

Once the `kustomization.yaml` commit lands in `main`, ArgoCD (running inside the Kubernetes cluster) detects the change within 3 minutes and:
1. Runs `kustomize build k8s/` to render all manifests
2. Compares rendered manifests to what's currently running in the cluster
3. Applies only the differences — a rolling update of pods with zero downtime

```yaml
syncPolicy:
  automated:
    prune: true      # removes resources that were deleted from git
    selfHeal: true   # if someone manually edits the cluster, ArgoCD reverts it
```

`selfHeal: true` is powerful — it means **git is always authoritative**. If someone panics and runs `kubectl edit deployment backend` manually to change something, ArgoCD will revert it within 3 minutes back to whatever git says.

---

## Pipeline 2: Infrastructure Pipeline (terraform.yml)

This pipeline only runs when Terraform files (`*.tf`) change. Application code changes don't trigger it.

**What is Terraform?**

Terraform is "Infrastructure as Code." Instead of clicking through the AWS console to create a VPC, EKS cluster, RDS database, etc., you write it in code. Terraform reads that code and creates/updates the actual AWS resources.

Benefits:
- Infrastructure changes are version-controlled (git history)
- Changes are reviewed in pull requests
- Exact same infrastructure can be recreated from scratch

### Steps

#### 1. Trivy IaC Scan

Before Terraform runs, Trivy scans the `.tf` files for **security misconfigurations**:
- S3 buckets that are publicly readable
- Security groups open to the entire internet
- RDS instances without encryption
- EKS clusters with overly permissive IAM roles

CRITICAL or HIGH misconfiguration = pipeline fails before anything is created.

#### 2. Terraform Format Check

```bash
terraform fmt -check -recursive
```

Enforces consistent formatting across all `.tf` files. Like ESLint but for Terraform. Fails if any file isn't properly formatted.

#### 3. Terraform Init

Downloads the provider plugins (AWS provider in this case) and connects to the remote state backend (S3 bucket storing current infrastructure state).

#### 4. Terraform Validate

Checks that the Terraform code is syntactically valid and internally consistent. Catches typos and missing required arguments before reaching AWS.

#### 5. Terraform Plan

This is the critical step. Terraform compares:
- Current state (what AWS resources exist right now, stored in S3)
- Desired state (what your `.tf` files say should exist)

And produces a **plan** — a diff showing exactly what will be created, modified, or destroyed.

```
Plan: 2 to add, 1 to change, 0 to destroy.
```

On **pull requests**, this plan is automatically posted as a comment so reviewers can see exactly what infrastructure changes will happen before approving the PR.

#### 6. Terraform Apply

Only runs on pushes to `main` (after a PR is merged). Executes the plan and makes the actual changes in AWS.

---

## End-to-End Flow: What Happens When You Push Code

```
Developer runs: git push origin main
                        │
                        ▼
          ┌─────────────────────────┐
          │   GitHub receives push  │
          │   Triggers both pipelines│
          └─────────────────────────┘
                        │
          ┌─────────────┴──────────────┐
          │                            │
          ▼                            ▼
   App Pipeline                 Infra Pipeline
   (if app files changed)       (only if .tf files changed)
          │
          ▼
   Stage 0: Gitleaks scans git history
          │ (PASS)
          ▼
   Stage 1 + 2 run in parallel:
   - npm audit (backend + frontend)
   - Semgrep SAST
   - ESLint
   - Kubeconform YAML validation
          │ (ALL PASS)
          ▼
   Stage 3: Build Docker images
            → Trivy scan each image
            → Push clean images to ECR
          │ (PASS)
          ▼
   Stage 4: [HUMAN APPROVAL REQUIRED]
            → Update kustomization.yaml with new image tag
            → Commit + push to main
          │
          ▼
   ArgoCD (running in EKS, polls every 3 min):
            → Detects new commit
            → Renders manifests via kustomize
            → Rolling update: new pods with new image come up,
              old pods terminate only after new ones are healthy
          │
          ▼
   Application is live with new code. Zero downtime.
```

---

## Security Summary

| Threat | How this pipeline defends |
|--------|--------------------------|
| Hardcoded secrets in code | Gitleaks scan on every commit (Stage 0) |
| Vulnerable npm packages | npm audit — HIGH/CRITICAL blocks deploy (Stage 1) |
| Insecure code patterns | Semgrep OWASP Top 10 rules (Stage 1) |
| CVEs in container OS/runtime | Trivy image scan — CRITICAL/HIGH blocks push (Stage 3) |
| Insecure AWS config | Trivy IaC scan of Terraform files (Infra pipeline) |
| Manual cluster drift | ArgoCD selfHeal reverts unauthorized changes |
| Leaked AWS credentials | OIDC authentication — no static keys exist anywhere |
| Accidental production deploy | Manual approval gate before Stage 4 |

---

## Key Terms Glossary

| Term | Plain English |
|------|---------------|
| **CI/CD** | Automated pipeline that tests and deploys code |
| **Docker image** | Packaged app + OS + dependencies in one shippable unit |
| **ECR** | AWS's private registry to store Docker images |
| **EKS** | AWS's managed Kubernetes service (runs your containers) |
| **Kubernetes** | System that runs and manages containers at scale |
| **Kustomize** | Tool to customize Kubernetes YAML files without duplicating them |
| **ArgoCD** | GitOps tool — watches git, keeps cluster in sync with it |
| **Terraform** | Code that creates and manages cloud infrastructure |
| **OIDC** | Authentication method — exchanges a temporary token for short-lived credentials |
| **SAST** | Analyzing source code for security issues without running it |
| **CVE** | Publicly known security vulnerability with an ID (e.g. CVE-2024-1234) |
| **Trivy** | Tool that scans Docker images and IaC files for CVEs and misconfigurations |
| **Gitleaks** | Tool that scans git history for accidentally committed secrets |
| **Semgrep** | Tool that scans source code against security rule sets |
| **GitOps** | Using git as the single source of truth for deployments |
| **Rolling update** | Updating pods one at a time so the app stays available during deployment |
