#!/usr/bin/env python3
"""
configure.py — Stamp real values into all project files that contain placeholders.

Run once after cloning, or any time you change config.env:
    python scripts/configure.py

In CI the values come from GitHub Secrets automatically — this script is for
local development / first-time setup only.
"""
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

PLACEHOLDERS = {
    "account": "ACCOUNT_ID",
    "domain":  "YOUR_DOMAIN_HERE.com",
    "repo":    "YOUR_GITHUB_USERNAME/aws_three_tier_code",
    "user":    "YOUR_GITHUB_USERNAME",
}


def load_config(path: Path) -> dict:
    cfg = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        cfg[key.strip()] = val.strip().strip('"').strip("'")
    return cfg


def substitute(rel_path: str, mapping: dict):
    p = REPO_ROOT / rel_path
    if not p.exists():
        print(f"  SKIP  {rel_path} (file not found)")
        return
    text = p.read_text(encoding="utf-8")
    original = text
    for old, new in mapping.items():
        text = text.replace(old, new)
    if text != original:
        p.write_text(text, encoding="utf-8")
        print(f"  [ok]  {rel_path}")
    else:
        print(f"  --{rel_path}  (already configured)")


def main():
    config_path = REPO_ROOT / "config.env"
    if not config_path.exists():
        sys.exit(
            "\nERROR: config.env not found.\n"
            "  1. cp config.env.example config.env\n"
            "  2. Fill in your real values\n"
            "  3. Re-run this script\n"
        )

    cfg = load_config(config_path)

    required = ["AWS_ACCOUNT_ID", "AWS_REGION", "DOMAIN", "GITHUB_REPO"]
    missing = [k for k in required if not cfg.get(k)]
    if missing:
        sys.exit(f"\nERROR: Missing values in config.env: {', '.join(missing)}\n")

    account_id  = cfg["AWS_ACCOUNT_ID"]
    region      = cfg["AWS_REGION"]
    domain      = cfg["DOMAIN"]
    github_repo = cfg["GITHUB_REPO"]
    github_user = github_repo.split("/")[0]

    print(f"\nConfiguring project with:")
    print(f"  Account : {account_id}")
    print(f"  Region  : {region}")
    print(f"  Domain  : {domain}")
    print(f"  Repo    : {github_repo}")
    print()

    # ── 1. terraform.tfvars ──────────────────────────────────────────────────
    tfvars = REPO_ROOT / "terraform.tfvars"
    tfvars.write_text(
        f'aws_region  = "{region}"\n'
        f'domain      = "{domain}"\n'
        f'github_repo = "{github_repo}"\n',
        encoding="utf-8",
    )
    print(f"  [ok]  terraform.tfvars  (generated)")

    # ── 2. k8s/ingress/ingress.yaml ──────────────────────────────────────────
    substitute("k8s/ingress/ingress.yaml", {
        PLACEHOLDERS["domain"]: domain,
    })

    # ── 3. k8s/argocd/application.yaml ───────────────────────────────────────
    # Replace repo first (longer match), then any leftover bare username
    substitute("k8s/argocd/application.yaml", {
        PLACEHOLDERS["repo"]: github_repo,
        PLACEHOLDERS["user"]: github_user,
    })

    # ── 4. k8s/kustomization.yaml ────────────────────────────────────────────
    # CI overwrites this on every push via `kustomize edit set image`.
    # This step only matters for the very first local apply before CI has run.
    substitute("k8s/kustomization.yaml", {
        f"{PLACEHOLDERS['account']}.dkr.ecr": f"{account_id}.dkr.ecr",
    })

    print(f"""
Done. Next steps
-----------------
1. First-time Terraform:
     terraform init
     terraform apply

2. Bootstrap the cluster (once per cluster):
     DOMAIN={domain} python eks_bootstrap.py

3. Commit k8s files so ArgoCD can sync:
     git add k8s/ingress/ingress.yaml k8s/argocd/application.yaml k8s/kustomization.yaml
     git commit -m "chore: configure for {domain}"
     git push
   (CI will rebuild images and ArgoCD will sync within 3 min.)

Note: config.env and terraform.tfvars are gitignored -- never commit them.
""")


if __name__ == "__main__":
    main()
