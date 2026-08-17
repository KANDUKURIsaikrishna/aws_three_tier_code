# The CI/CD Pipeline, Explained So You Can Teach It — No Doubts Left

This covers one file: `.github/workflows/ci-cd.yml`, named `DevSecOps Pipeline` inside GitHub Actions. It's the automated process that turns a `git push` into running code, with a security gate at nearly every step. A separate, sibling workflow (`terraform.yml`) handles *infrastructure* changes — this document is about the *application* pipeline only; don't merge the two in your head, they have different triggers and different approval rules.

---

## Part 0: What is CI/CD, explained with zero jargon

Picture a bakery that ships bread to grocery stores. Nobody wants a loaf that used a banned ingredient, has metal shavings in it, or is undercooked to reach the shelf. So before any loaf leaves the building, it passes through a series of checkpoints, each one independent, each one able to pull the whole batch off the line:

1. Someone checks the recipe card itself for banned ingredients, before any baking starts.
2. The dough is tested for known problems (bad flour batch, wrong proportions).
3. The oven-baked loaf is X-rayed for anything dangerous baked inside it.
4. Only after every check passes does a shift manager physically sign a shipping form.
5. And even then, the loaf doesn't teleport to the store — a separate delivery truck, running its own schedule, picks up whatever's marked "ready to ship" and drives it over.

**That entire chain is what "CI/CD" means, translated:** **CI (Continuous Integration)** is everything up through "the product is built and verified safe" — the recipe check, the dough test, the X-ray. **CD (Continuous Delivery/Deployment)** is everything about actually getting the verified product to where customers can have it — the shipping form and the delivery truck. This project draws that exact line explicitly, and it's one of the most important ideas in the whole pipeline: **CI's job ends the moment the product is verified and marked ready. A separate, independent process (ArgoCD, covered in the Kubernetes doc) is the only thing that actually delivers it to the running application** — GitHub Actions never reaches into the live system directly, the same way the bakery's oven crew never personally drives the delivery truck.

**Why bother with all these separate, automated checkpoints instead of a human just reviewing the code and clicking deploy?** Two reasons worth having ready: consistency (a human reviewer might be tired, might miss something on a Friday afternoon; the same automated check runs identically, every single time, on every single change) and speed (every checkpoint above runs in minutes, in parallel where possible, instead of waiting on a human's calendar). The tradeoff, worth naming honestly: automation only catches what it's specifically built to catch — it's not a substitute for a human occasionally reviewing whether the checks themselves are still the right ones.

**One more foundational idea: what does "trigger" mean, and why do only some branches get every stage?** A trigger is the event that starts the whole pipeline — here, a `git push` or a pull request to one of three specific branches (`main`, `improvements`, `observability`). But not every branch is treated equally past that: `improvements` gets every check and even gets its container images built and pushed to the registry, but it **never** gets the final "actually deliver this" stage — only `main` and `observability` do. That's a deliberate policy, not an oversight: "feature branches get full CI, only the branches meant to represent real, running environments get CD."

---

## Part 1: Every stage, in the order they run, with the exact mechanics

### The trigger and the traffic rule at the very top

```yaml
on:
  push:
    branches: [main, improvements, observability]
  pull_request:
    branches: [main, improvements, observability]
```

Both a direct push to one of these three branches, and a pull request *targeting* one of them, start the pipeline. This matters for a common point of confusion: opening a PR from a feature branch into `observability` runs the full pipeline against the PR's proposed merge, even though the feature branch itself isn't in this list — the *target*, not the source, is what's checked.

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: false
```

This is a traffic-control rule, and it's worth being precise about what it actually prevents. `group` names a lane per-branch (the workflow name plus the branch reference) — meaning two different branches can run simultaneously without interfering, but two pushes to the *same* branch, close together, share a lane. `cancel-in-progress: false` means the second run doesn't kill the first one — it queues, and waits its turn. **Why not just cancel the older, now-outdated run, which sounds more efficient?** Because the `deploy` stage (covered below) ends by committing a file change and pushing it to git — if a run got cancelled mid-way through that specific step, you could be left with a half-written, corrupted commit. Queuing costs a few extra minutes sometimes; a corrupted deploy commit costs a lot more to untangle. This is a deliberate safety-over-speed tradeoff.

### Stage 0 — 🔐 Secret Scan (Gitleaks) — the recipe-card check

```yaml
secret-scan:
  permissions:
    contents: read
  steps:
    - uses: actions/checkout@...  # fetch-depth: 0
    - uses: gitleaks/gitleaks-action@...
```

`fetch-depth: 0` means "check out the **entire** git history, not just the latest commit" — the default, shallow checkout only grabs the most recent snapshot, which would let a secret that was committed and later "removed" in a follow-up commit slip through undetected (it's still sitting in history, in that earlier commit, forever, unless the repo's history itself is rewritten — a real, separate, disruptive operation). Gitleaks scans every commit in that full history for patterns that look like API keys, private keys, passwords, and similar. **This runs first, before literally anything else, and everything else waits on it (`needs: secret-scan` appears on the very next two jobs) — the one absolute, no-exceptions gate in the whole pipeline.** The reasoning: there's no point spending compute minutes testing, scanning, or building code from a commit that might need to be scrubbed from history entirely.

`permissions: {contents: read}` is worth noting as its own small security practice, repeated on every job in this file: by default, GitHub Actions grants a job's token broad permissions; this file explicitly narrows every single job down to exactly the permissions it needs and nothing more — `secret-scan` only ever needs to *read* the repository, never write to it.

### Stage 1 — 🛡️ SAST & Dependency Audit — the dough test

Runs in parallel with Stage 2 (both only wait on `secret-scan`, not on each other — worth noticing `needs: secret-scan` on both `sast` and `validate`, and the *absence* of any dependency between the two of them). Node 22 is set up once, with `cache-dependency-path` pointing at all 6 `package-lock.json` files at once — this is a real, concrete performance detail: GitHub Actions can restore a cached `node_modules` install *per lockfile*, meaning if only `order-service`'s dependencies changed since the last run, the other 5 services' `npm ci` steps restore from cache almost instantly instead of re-downloading everything from the internet every single run.

For each of the 5 backend services, in turn: `npm ci` (a clean, lockfile-exact install — different from `npm install`, which can update the lockfile itself; `ci` is what you want in an automated pipeline, since it fails loudly if the lockfile and `package.json` have drifted apart, rather than silently "fixing" it), then `npm test`, then `npm audit --audit-level=high --omit=dev` — a dependency vulnerability scan that fails the build on any known HIGH or CRITICAL severity issue in a *production* dependency (`--omit=dev` deliberately excludes dev-only tooling, like the test runner itself, from this check — a vulnerability in a tool that never ships to production isn't the same risk as one that does).

The frontend (`client/`) gets the same treatment but with one real, honestly-documented exception: `npm audit --audit-level=critical`, not `high`. The comment right in the workflow explains why: Create React App's own build tooling (`react-scripts`) has known, unfixed HIGH-severity findings in its dependency tree that nobody can patch from this project's side — holding the frontend to the same `high` bar as the backend services would make the pipeline permanently, unfixably red for a risk that doesn't actually reach production (the vulnerable code is *build-time* tooling, never shipped in the final static bundle users' browsers load). This is a real, deliberate, judgment-call exception — not a mistake, and worth being able to defend the reasoning behind it if asked "why is the frontend's bar lower."

**Semgrep**, the last step, is a different kind of check entirely — not "does a dependency have a known CVE," but **static analysis of your own code** for dangerous *patterns*, independent of any specific published vulnerability. `--config p/nodejs` + `p/owasp-top-ten` + `p/secrets` are three separate, pre-built rule packs (Node.js-specific bad patterns, the OWASP Top 10 web vulnerability categories — SQL injection shapes, unsafe deserialization, and similar — and a second, code-pattern-based secrets check layered on top of Gitleaks' history-based one). `--error` means any single finding fails the whole step, not just a warning in the log.

### Stage 2 — ✅ Lint & Validate — the second, parallel check

Two unrelated checks bundled into one job because both are fast and both only need the frontend's dependencies installed (`kubeconform` needs no `npm` install at all — it's a standalone binary). **ESLint** (`--max-warnings=0`) enforces the frontend's code style and catches a category of real bugs (unused variables, unreachable code, common React mistakes) — zero tolerance, meaning even a *warning*, not just an error, fails the build. This is a deliberate strictness choice: warnings that are "allowed to exist" tend to accumulate indefinitely in a real codebase, because nothing ever forces anyone to actually look at them.

**`kubeconform`** validates every Kubernetes YAML file under `k8s/` (explicitly excluding `kustomization.yaml` files, which aren't standalone Kubernetes objects on their own — they're Kustomize's own instruction files, a different thing kubeconform doesn't know how to validate) against the real Kubernetes 1.31 API schema. **What this catches, precisely:** a typo'd field name, a value of the wrong type, a required field left out — structural mistakes that would otherwise only surface much later, as a confusing error from ArgoCD *after* it already tried and failed to apply the manifest to the real cluster. Catching it here, in seconds, on every single commit, is strictly cheaper than catching it there.

### Stage 3 — 🐳 Build → Trivy Scan → Push — the X-ray

The first job gated by an `if:` condition — `github.ref == 'refs/heads/main' || ... == 'refs/heads/improvements' || ... == 'refs/heads/observability'` — meaning a pull request from some other branch runs every check above, but never reaches this stage or spends any money building and pushing real container images. Also the first job needing real AWS access, hence the extra `permissions: {id-token: write, ...}` (the specific permission GitHub Actions requires to be allowed to mint an OIDC identity token at all — without it, the credentials step below has nothing to present to AWS).

**The exact sequence, once per service, 6 times total (5 backend services + frontend):**
1. `docker/build-push-action` with `push: false, load: true` — builds the image and loads it into the local Docker daemon, but does **not** push it anywhere yet. This ordering is the whole point of this stage's design: nothing ever reaches the registry before it's been scanned.
2. Trivy scans that *local*, unpushed image. `severity: CRITICAL,HIGH` + `exit-code: "1"` means the step itself fails the job the moment either severity is found. `ignore-unfixed: true` is a deliberate, important nuance: a CVE with **no available patch yet** doesn't fail the build — because failing on something nobody can currently fix would mean the pipeline is permanently red through no fault of anyone touching this code, for a risk you have no way to act on today. Only fixable-but-unfixed vulnerabilities block the pipeline.
3. On failure specifically (`if: failure()`), a diagnostic step parses the SARIF results file with `jq` and prints a clean, human-readable list of exactly which CVEs were found directly into the CI log — without this, you'd have to download a machine-formatted SARIF file and dig through it by hand just to see what broke.
4. The SARIF results upload to GitHub's own Security tab **unconditionally** (`if: always()`), pass or fail — so even a passing scan's results are visible and trackable over time, not just failures.
5. **Only after the scan step has already succeeded** (a failed step stops the job right there — GitHub Actions steps run sequentially and a failure halts the remaining steps in that job by default) does `docker push` actually happen. An image with an unpatched CRITICAL or HIGH CVE is, by construction, never pushed — not "flagged," not "pushed with a warning label," genuinely never uploaded to the registry at all.

**The image tag itself** — `${GITHUB_SHA::8}` — is the first 8 characters of the git commit hash that triggered this run, computed once at the very top of the job and reused for every one of the 6 images. This is a deliberate traceability choice: given any running container in production, you can always work backward to the *exact* commit that produced it, just from the tag — no separate version-numbering scheme to keep in sync by hand, and no ambiguity about which specific commit's code is actually running.

**Authentication, the part worth being able to explain precisely:** `aws-actions/configure-aws-credentials` with `role-to-assume: ${{ secrets.AWS_ROLE_ARN }}` triggers GitHub's OIDC-to-AWS-STS exchange (the exact cryptographic chain — GitHub's signed token, AWS independently verifying it against the pre-registered OIDC provider, checking the token's claims against the IAM role's trust policy — is described precisely in the Terraform doc's deep-mechanics section; the short version here is: **no `AWS_ACCESS_KEY_ID` or `AWS_SECRET_ACCESS_KEY` exists anywhere in this pipeline, only a short-lived, automatically-expiring credential minted fresh for this one job run**).

**Every third-party GitHub Action in this file is pinned to a full 40-character commit SHA**, visible right after the `@` in every `uses:` line (`actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5`), not a friendly version tag like `@v4`. This is a real, deliberate supply-chain security decision worth being able to defend on its own: a version tag like `v4` is **mutable** — its maintainer (or an attacker who compromises that maintainer's account) can silently repoint it to different, potentially malicious code at any time, and every pipeline using `@v4` would pull the new code on its very next run, without anyone having reviewed or approved anything. A commit SHA is **immutable** — it can never be repointed, ever; upgrading to a newer version requires someone to deliberately edit this file to a new SHA, a reviewable, visible change, exactly like any other code change. The trailing `# v4` comment is purely a human-readable label; it has zero effect on what code actually runs.

### Stage 4 — 🚀 Update image tags (GitOps → ArgoCD) — the shipping form and the loading dock

The narrowest-gated job in the file: `needs: build-and-push` (so every image must already be built, scanned clean, and pushed) **and** `if: github.ref == 'refs/heads/main' || ... == 'refs/heads/observability'` — deliberately excluding `improvements`, which built and pushed real images in the previous stage but never gets them deployed. `environment: production` is the one line that actually creates the human approval gate: GitHub Environments can be configured (outside this YAML file, in the repository's own settings) with "required reviewers," and when a job targets a protected environment, GitHub Actions literally pauses the job — not a timeout, not a retry, a genuine wait — until someone with permission clicks approve in the GitHub UI. **This is the only manual, human-in-the-loop step in the entire pipeline.**

**What this job actually does, and the one sentence worth memorizing:** it edits 6 small YAML files and pushes a git commit. It does **not** run `kubectl`, does **not** have cluster credentials of any kind, and could not reach into the running Kubernetes cluster even if it tried — `kustomize edit set image` is a purely local, offline text-editing operation against the checked-out files. For each of the 6 services, in its own overlay directory, it rewrites the `newTag` value to the freshly-built image's tag, then stages all 6 changed files, commits with a fixed message format (`chore: bump image tags to <tag>`), and pushes.

**The specific, deliberate detail preventing an infinite loop:** the checkout step explicitly uses `token: ${{ secrets.GITHUB_TOKEN }}` — GitHub's own built-in, automatically-provided token for the current workflow run — and GitHub Actions has a hard, platform-level rule that **pushes made using that specific, automatic token never trigger a new workflow run**, even though this exact push lands on `main`/`observability`, branches this same workflow is normally triggered by. Without that rule (or if a different, personal-access-token-style credential were used instead), this job's own push would trigger the whole pipeline again, which would eventually reach this same job again, which would push again — a genuine infinite loop, entirely avoided here by relying on a specific, documented platform guarantee rather than by any cleverness in this file's own logic.

**One more small but real detail:** `git diff --staged --quiet && echo "No image tag changes." && exit 0` — if, for whatever reason, none of the 6 files actually changed (extremely unlikely given a fresh tag every run, but a real defensive check), the job exits cleanly instead of attempting an empty commit, which Git would refuse and turn into a confusing failure instead of a harmless no-op.

**And then — nothing else happens in this pipeline.** The commit is pushed, the job ends, GitHub Actions' job is done. Whether that change actually reaches the running application is now entirely the responsibility of ArgoCD, running inside the cluster, on its own independent 3-minute poll cycle — a process this file has no knowledge of, no dependency on, and no ability to trigger directly. That handoff — a `git push` on one side, an unrelated, autonomous poll loop on the other, connected only by both reading the same git repository — is the literal CI/CD boundary this whole document opened by naming.

---

## Part 2: The mechanics, precisely — no doubts left

### Why jobs, not steps, run in parallel — the actual scheduling model

A GitHub Actions workflow is made of **jobs**, and each job runs on its own separate, freshly-provisioned virtual machine (`runs-on: ubuntu-latest`) — jobs do not share memory, disk, or process state with each other at all, only whatever's explicitly checked out from git again at the start of each one. **Steps within one job run strictly sequentially**, on that one shared machine, and a failed step stops every subsequent step in that same job (unless a later step explicitly opts out with `if: failure()` or `if: always()`, both used deliberately in this file for diagnostics and SARIF uploads). **Jobs, on the other hand, run in parallel by default** — the only thing that forces one job to wait for another is an explicit `needs:` line, which is exactly the mechanism controlling this pipeline's whole shape: `sast` and `validate` both `needs: secret-scan` and nothing else, so GitHub Actions schedules them onto two separate machines the instant `secret-scan` finishes, running genuinely simultaneously — this is why the pipeline's real wall-clock time is roughly `secret-scan` + `max(sast, validate)` + `build-and-push` + (a human's approval delay) + `deploy`, not the sum of every single job.

### What OIDC federation actually replaces, mechanically, step by step

The traditional, older pattern this pipeline deliberately avoids: generate a static AWS IAM user, generate a permanent access key + secret key pair for it, paste that pair into GitHub's encrypted secrets storage, and have every single workflow run, forever, use that same unchanging credential. The specific weaknesses that pattern carries, worth naming precisely: the credential works identically whether it's genuinely GitHub Actions using it or someone who stole it from a leaked log line, a compromised dependency, or a misconfigured secret; it doesn't expire on its own, ever, until a human notices and manually rotates it; and it grants exactly the same access to every single workflow run, with no way to distinguish "this is workflow X on branch Y" from "this is some other request entirely."

**What actually happens instead, mechanically, in this pipeline's `configure-aws-credentials` step:** GitHub's own OIDC token-issuing service (built into every Actions runner, no extra setup needed on GitHub's side) generates a JWT specific to *this exact job run* — containing claims like the repository, the branch or ref, and the specific workflow file — and cryptographically signs it with a private key only GitHub holds. That token is presented to AWS Security Token Service via the `AssumeRoleWithWebIdentity` API call. AWS, separately and independently, verifies the signature against GitHub's *public* key (fetched once, in advance, when the OIDC identity provider was registered in this project's `iam.tf` — see the Terraform doc), confirming the token is genuinely from GitHub and hasn't been tampered with. Only then does AWS check the token's claims against the target IAM role's trust policy — in this project's case, a `StringLike` condition on the exact repository name and one of exactly three allowed branch refs. If every check passes, STS hands back temporary AWS credentials — an access key, secret key, and session token, all three valid for a bounded window measured in a small number of hours — that exist *only* for the remainder of this one job. **No credential capable of acting as this pipeline exists anywhere before the job starts, and nothing capable of acting as it persists after the job ends.**

### The full trust chain from a `git push` to a running pod, laid end to end

Worth being able to recite this whole chain without stopping, since it's the single most likely "walk me through the whole system" question:

1. A developer runs `git push`, landing a commit on `main` or `observability`.
2. GitHub's servers see the push matches this workflow's trigger and start `secret-scan`.
3. `secret-scan` passes → `sast` and `validate` start in parallel.
4. Both pass → `build-and-push` starts (only if the branch is one of the three allowed): 6 images built, each scanned by Trivy, each pushed to ECR only if its own scan came back clean.
5. `build-and-push` finishes → `deploy` starts, but immediately pauses at the `environment: production` gate, waiting on a human.
6. A human clicks approve → `deploy` resumes: 6 `kustomization.yaml` files get their image tag fields rewritten, committed, and pushed — using `GITHUB_TOKEN`, so this push does **not** restart the pipeline.
7. GitHub Actions' job ends. **From this exact point, GitHub Actions has no further role.**
8. Independently, on its own clock, ArgoCD's controller — running inside the Kubernetes cluster, having nothing to do with GitHub Actions at all beyond both reading the same repository — polls the git repository (every 3 minutes) and notices the `kustomization.yaml` files changed since its last check.
9. ArgoCD renders the new manifests (`kustomize build` against the changed overlay), computes a diff against what's actually running in the cluster right now, and applies exactly that diff — which for a routine image-tag bump means: update the Deployment's container image reference, which Kubernetes then rolls out as a normal, zero-downtime rolling update (old pods stay serving traffic until new ones pass their readiness probe, exactly as described in the Kubernetes doc).
10. The new code is now genuinely running and serving real traffic — anywhere from a few seconds up to just under 3 minutes after the human clicked approve, depending purely on where ArgoCD's poll cycle happened to be at that moment.

**The one thing worth stressing if this chain comes up:** step 7 to step 8 crosses a real, deliberate system boundary. Nothing in this pipeline calls, triggers, waits for, or even knows that ArgoCD exists. If ArgoCD were down, broken, or misconfigured, this entire pipeline would still run green, top to bottom, "successfully" — the git commit would be sitting there, correct and waiting, and the running application simply wouldn't have picked it up yet. That's the honest cost of the GitOps decoupling this project deliberately chose: total transparency and a clean git-as-source-of-truth model, at the cost of CI never being able to promise "and now it's live" the way a pipeline that called `kubectl` directly could.

---

## Questions you should be ready for

**"Why does the pipeline never call `kubectl` directly — wouldn't that be simpler?"**
It would be *simpler*, and it's a completely reasonable design some real companies use. The tradeoff this project chose instead: git becomes the single, provable source of truth for "what should be running," and the cluster continuously, independently reconciles itself to match it — meaning a stray manual `kubectl edit` gets automatically reverted, and there's a full audit trail of every deployment as ordinary git commits. The cost is exactly what the trust-chain walkthrough above ends on: CI can never promise "it's live now," only "it's ready, and queued for the next poll."

**"What happens if Trivy finds a HIGH vulnerability in a base image you don't control, like `node:22-alpine`?"**
If a fix is available upstream, the build fails until the base image (or the specific vulnerable package) is updated — exactly the intended behavior. If no fix exists yet anywhere (`ignore-unfixed: true`), the build is allowed through, but the finding is still visible in GitHub's Security tab from the unconditional SARIF upload — visible and tracked, not silently ignored, just not blocking.

**"Why 3 separate scanning tools (Gitleaks, Semgrep, Trivy) instead of one?"**
Because they check three genuinely different things, at three different layers: Gitleaks checks *git history* for secrets that were ever committed. Semgrep checks your *own source code* for dangerous patterns, independent of any specific published vulnerability. Trivy checks the *built container image* — its OS packages and installed dependencies — against databases of known, published CVEs. None of the three could catch what either of the other two catches; using only one would leave two entire categories of real risk unchecked.

**"How would you add a 7th microservice to this pipeline?"**
Precisely, from the file itself: a new `env:` entry for its ECR repo name, 3 new steps in `sast` (install/test/audit), a new build-Trivy-push block (copy-paste one of the existing 5, rename) in `build-and-push`, and one new `kustomize edit set image` line plus a `git add` entry in `deploy`. Worth noting honestly: this file's repetitive, copy-pasted-per-service structure (explicitly a deliberate choice over a matrix loop, for per-service Dockerfile-context clarity — see the file's own stage comments) means adding a service is mechanical but genuinely touches several places in one file, not one clean, isolated change — a real, named tradeoff of readability over the more copy-paste-resistant matrix-strategy alternative GitHub Actions also supports.

**"What's the actual difference between `sast`/`validate` failing versus `build-and-push` failing?"**
`sast`/`validate` failing means the *source code itself* has a problem (a bug the tests caught, a known-vulnerable dependency, a lint violation, an invalid manifest) — nothing was ever built. `build-and-push` failing on a Trivy finding means the *source code passed*, but the resulting container image — including its base OS layer and every transitive dependency baked into the final artifact — has a real vulnerability. The second is a strictly later, more expensive-to-reach checkpoint, which is exactly why the cheap checks (secret scan, lint, unit tests) all run and must pass *first*, before any time or compute is spent building 6 real container images.

## Related

- [`ARCHITECTURE_EXPLAINED.md`](ARCHITECTURE_EXPLAINED.md) — where ArgoCD, IRSA, and the OIDC trust chain are covered from the infrastructure side
- [`TERRAFORM_EXPLAINED.md`](TERRAFORM_EXPLAINED.md) — `iam.tf` (the OIDC role this pipeline assumes) and the exact STS mechanics, in more depth
- [`KUBERNETES_EXPLAINED.md`](KUBERNETES_EXPLAINED.md) — what ArgoCD does with the commit this pipeline produces, step by step
- [`DOCKER_EXPLAINED.md`](DOCKER_EXPLAINED.md) — what actually happens inside the `build-and-push` job's build/scan/push steps: the Dockerfiles themselves
- The real source this was built from: `../.github/workflows/ci-cd.yml`, `../docs/CICD_DIAGRAM_PROMPT.md`
