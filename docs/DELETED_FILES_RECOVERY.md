# Deleted Files — `observability` Branch Cleanup

**Date:** 2026-07-29
**Branch:** `observability`
**Reason:** Phase 1/2 narrative docs, diagrams, and stray artifacts removed to
keep this branch's workspace focused on the microservices + observability
work (see [`docs/superpowers/specs/2026-07-29-microservices-observability-design.md`](superpowers/specs/2026-07-29-microservices-observability-design.md)).

**Nothing was deleted from `main` or `improvements`** — git branches are
independent; these files are untouched and still present there. This only
affects the `observability` branch's working tree going forward.

## Recovery

Every file below (except `errored.tfstate`) is still tracked in git history —
recoverable from either of these branches, or from this branch's own history
prior to the deletion commit:

```bash
# from a source branch (has the full original file)
git checkout improvements -- <path>

# or from this branch's own history, right before the cleanup commit
git checkout <this-commit-hash>^ -- <path>
```

Source branch tip at time of deletion:
- `improvements` @ `4bc2925f2189ae98c18d61d5c00a6b84b21ee021`
- `observability` branched from `improvements`, deletion committed on top

## Deleted (tracked, recoverable)

| File | Recover with |
|---|---|
| `IMPROVEMENTS_PLAN.md` | `git checkout improvements -- IMPROVEMENTS_PLAN.md` |
| `IMPLEMENTATION_GUIDE.md` | `git checkout improvements -- IMPLEMENTATION_GUIDE.md` |
| `FUTURE.md` | `git checkout improvements -- FUTURE.md` |
| `CICD_DOCS.md` | `git checkout improvements -- CICD_DOCS.md` |
| `TERRAFORM_DOCS.md` | `git checkout improvements -- TERRAFORM_DOCS.md` |
| `K8S_EXPLAINED.md` | `git checkout improvements -- K8S_EXPLAINED.md` |
| `TROUBLESHOOTING.md` | `git checkout improvements -- TROUBLESHOOTING.md` |
| `PROJECT_SUMMARY.md` | `git checkout improvements -- PROJECT_SUMMARY.md` |
| `PROJECT_ARCHITECTURE.md` | `git checkout improvements -- PROJECT_ARCHITECTURE.md` |
| `README 2.md` | `git checkout improvements -- "README 2.md"` |
| `BRAINSTORM_AGILE_PHASES.md` | `git checkout improvements -- BRAINSTORM_AGILE_PHASES.md` |
| `docs/phase-2-architecture.md` | `git checkout improvements -- docs/phase-2-architecture.md` |
| `docs/phase-2-future-improvements.md` | `git checkout improvements -- docs/phase-2-future-improvements.md` |
| `docs/phase-2-implementation.md` | `git checkout improvements -- docs/phase-2-implementation.md` |
| `docs/phase-2-improvements.md` | `git checkout improvements -- docs/phase-2-improvements.md` |
| `docs/phase-2-troubleshooting.md` | `git checkout improvements -- docs/phase-2-troubleshooting.md` |
| `docs/cicd.md` | `git checkout improvements -- docs/cicd.md` |
| `docs/terraform.md` | `git checkout improvements -- docs/terraform.md` |
| `docs/kubernetes.md` | `git checkout improvements -- docs/kubernetes.md` |
| `docs/observability.md` | `git checkout improvements -- docs/observability.md` (pre-EC2-migration version; superseded by this branch's new observability work) |
| `docs/eks-upgrade-runbook.md` | `git checkout improvements -- docs/eks-upgrade-runbook.md` |
| `docs/diagram-1-full-system-architecture.md` | `git checkout improvements -- docs/diagram-1-full-system-architecture.md` |
| `docs/diagram-prompts.md` | `git checkout improvements -- docs/diagram-prompts.md` |
| `docs/diagram-prompts-aws-style.md` | `git checkout improvements -- docs/diagram-prompts-aws-style.md` |

## Deleted (NOT recoverable)

| File | Why not recoverable | Notes |
|---|---|---|
| `errored.tfstate` | Was never git-tracked (untracked working-tree file) | Raw Terraform state dump (~139KB) from a failed apply, superseded by real backend state. Permanently gone — no git history for it on any branch. |

## To restore everything (undo this whole cleanup)

```bash
git checkout improvements -- \
  IMPROVEMENTS_PLAN.md IMPLEMENTATION_GUIDE.md FUTURE.md CICD_DOCS.md \
  TERRAFORM_DOCS.md K8S_EXPLAINED.md TROUBLESHOOTING.md PROJECT_SUMMARY.md \
  PROJECT_ARCHITECTURE.md "README 2.md" BRAINSTORM_AGILE_PHASES.md \
  docs/phase-2-architecture.md docs/phase-2-future-improvements.md \
  docs/phase-2-implementation.md docs/phase-2-improvements.md \
  docs/phase-2-troubleshooting.md docs/cicd.md docs/terraform.md \
  docs/kubernetes.md docs/observability.md docs/eks-upgrade-runbook.md \
  docs/diagram-1-full-system-architecture.md docs/diagram-prompts.md \
  docs/diagram-prompts-aws-style.md
```

(`errored.tfstate` cannot be restored this way — it was never committed.)
