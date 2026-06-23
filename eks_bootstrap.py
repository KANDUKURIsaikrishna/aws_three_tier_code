"""
eks_bootstrap.py — Full EKS cluster post-provisioning bootstrap.

Run this ONCE after every `terraform apply` that creates/recreates the cluster.
It is safe to re-run (all steps are idempotent).

Prerequisites:
  - terraform apply completed successfully
  - aws CLI configured with admin credentials
  - kubectl, helm installed and on PATH
  - Python 3.8+

Usage:
  python eks_bootstrap.py
"""

import base64
import datetime
import getpass
import json
import os
import shutil
import subprocess
import sys
import time
import secrets as secrets_mod

# ── Config ────────────────────────────────────────────────────────────────────

CLUSTER_NAME  = "bookstore-eks"
REGION        = "us-west-1"
APP_NAMESPACE = "bookstore"
# Set DOMAIN env var before running: DOMAIN=your-domain.com python eks_bootstrap.py
DOMAIN = os.environ.get("DOMAIN", "")
if not DOMAIN:
    sys.exit("ERROR: DOMAIN env var not set. Example: DOMAIN=your-domain.com python eks_bootstrap.py")

# IAM resource names (created by this script via CLI, not Terraform)
IRSA_ROLE_NAME   = "bookstore-external-secrets-irsa"
IRSA_POLICY_NAME = "bookstore-secretsmanager-read"

# AWS Secrets Manager path — must match k8s/secrets/external-secret.yaml
DB_SECRET_ID = "/bookstore/db-credentials"

# Database name the backend app expects (matches k8s/configmaps/backend-config.yaml)
DB_NAME = "test"

# ── Helpers ───────────────────────────────────────────────────────────────────

def header(msg: str):
    print(f"\n{'='*70}\n>>> {msg}\n{'='*70}\n", flush=True)


def run(command: list, check: bool = True, capture: bool = False) -> str:
    """Run a command, streaming output live. Returns stdout if capture=True."""
    if capture:
        result = subprocess.run(command, capture_output=True, text=True)
        return result.stdout.strip()

    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    while True:
        line = process.stdout.readline()
        if not line and process.poll() is not None:
            break
        if line:
            sys.stdout.buffer.write(line)
            sys.stdout.flush()
    rc = process.poll()
    if rc != 0 and check:
        print(f"\n❌ Command failed (exit {rc}): {' '.join(command)}", file=sys.stderr)
        sys.exit(rc)
    return ""


def run_ok(command: list) -> bool:
    """Run a command silently. Returns True if it exits 0."""
    result = subprocess.run(command, capture_output=True)
    return result.returncode == 0


def capture(command: list) -> str:
    """Run a command and return stripped stdout."""
    return subprocess.run(command, capture_output=True, text=True).stdout.strip()


# ── Phase 1: kubeconfig ───────────────────────────────────────────────────────

header("Phase 1: Syncing EKS kubeconfig...")
run(["aws", "eks", "update-kubeconfig",
     "--name", CLUSTER_NAME, "--region", REGION])
run(["kubectl", "get", "nodes"])

# ── Phase 2: ClusterIssuer ─────────────────────────────────────────────────────
# cert-manager, ESO, ingress-nginx, and ArgoCD are managed by Terraform
# (modules/eks-addons). By the time this script runs, those helm_release
# resources are already ACTIVE. Apply the ClusterIssuer CRD instance here.

header("Phase 2: Applying ClusterIssuer...")
issuer_file = os.path.join(os.path.dirname(__file__), "cluster-issuer.yaml")
if os.path.exists(issuer_file):
    run(["kubectl", "apply", "-f", issuer_file])
else:
    print("⚠️  cluster-issuer.yaml not found — skipping ClusterIssuer.")

# ── Phase 3: IRSA for external-secrets-sa ────────────────────────────────────
#
# The ClusterSecretStore uses a service account (external-secrets-sa) in the
# external-secrets namespace. That SA needs an IAM role (IRSA) with Secrets
# Manager read permission.
#
# IMPORTANT: The EKS OIDC provider URL is cluster-specific and changes every
# time the cluster is destroyed and recreated. This phase always updates the
# trust policy to match the current cluster, so re-running after a destroy is safe.
# ─────────────────────────────────────────────────────────────────────────────

header("Phase 3: IRSA for external-secrets-sa...")

account_id = capture(["aws", "sts", "get-caller-identity",
                       "--query", "Account", "--output", "text"])
oidc_url   = capture(["aws", "eks", "describe-cluster",
                       "--name", CLUSTER_NAME, "--region", REGION,
                       "--query", "cluster.identity.oidc.issuer", "--output", "text"])
oidc_id    = oidc_url.replace("https://", "")

print(f"  Account ID:    {account_id}")
print(f"  OIDC provider: {oidc_id}")

irsa_policy_arn = f"arn:aws:iam::{account_id}:policy/{IRSA_POLICY_NAME}"
irsa_role_arn   = f"arn:aws:iam::{account_id}:role/{IRSA_ROLE_NAME}"

# 5a. Ensure the Secrets Manager read policy exists
if not run_ok(["aws", "iam", "get-policy", "--policy-arn", irsa_policy_arn]):
    print(f"Creating IAM policy {IRSA_POLICY_NAME}...")
    policy_doc = json.dumps({
        "Version": "2012-10-17",
        "Statement": [{
            "Effect": "Allow",
            "Action": [
                "secretsmanager:GetSecretValue",
                "secretsmanager:DescribeSecret"
            ],
            "Resource": f"arn:aws:secretsmanager:{REGION}:{account_id}:secret:/bookstore/*"
        }]
    })
    run(["aws", "iam", "create-policy",
         "--policy-name", IRSA_POLICY_NAME,
         "--policy-document", policy_doc])
else:
    print(f"✅ IAM policy {IRSA_POLICY_NAME} already exists.")

# 5b. Build trust policy pointing to the CURRENT cluster OIDC provider
trust_policy = json.dumps({
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Principal": {
            "Federated": f"arn:aws:iam::{account_id}:oidc-provider/{oidc_id}"
        },
        "Action": "sts:AssumeRoleWithWebIdentity",
        "Condition": {
            "StringEquals": {
                f"{oidc_id}:aud": "sts.amazonaws.com",
                f"{oidc_id}:sub": "system:serviceaccount:external-secrets:external-secrets-sa"
            }
        }
    }]
})

# 5c. Create the IRSA role (or update its trust policy if the cluster was recreated)
if not run_ok(["aws", "iam", "get-role", "--role-name", IRSA_ROLE_NAME]):
    print(f"Creating IRSA role {IRSA_ROLE_NAME}...")
    run(["aws", "iam", "create-role",
         "--role-name", IRSA_ROLE_NAME,
         "--assume-role-policy-document", trust_policy])
    run(["aws", "iam", "attach-role-policy",
         "--role-name", IRSA_ROLE_NAME,
         "--policy-arn", irsa_policy_arn])
else:
    # Role exists — always update the trust policy because the EKS OIDC provider
    # URL changes every time the cluster is destroyed and recreated.
    print(f"✅ IRSA role {IRSA_ROLE_NAME} exists — updating trust policy for new cluster OIDC...")
    run(["aws", "iam", "update-assume-role-policy",
         "--role-name", IRSA_ROLE_NAME,
         "--policy-document", trust_policy])

# 5d. Create external-secrets-sa service account if it doesn't exist
if not run_ok(["kubectl", "get", "serviceaccount", "external-secrets-sa",
               "-n", "external-secrets"]):
    print("Creating external-secrets-sa service account...")
    run(["kubectl", "create", "serviceaccount", "external-secrets-sa",
         "-n", "external-secrets"])

# 5e. Annotate the SA with the IRSA role ARN
run(["kubectl", "annotate", "serviceaccount", "external-secrets-sa",
     "-n", "external-secrets",
     f"eks.amazonaws.com/role-arn={irsa_role_arn}",
     "--overwrite"])
print(f"✅ IRSA: external-secrets-sa → {irsa_role_arn}")

# Restart ESO so pods pick up the new IRSA annotation
run(["kubectl", "rollout", "restart", "deployment/external-secrets", "-n", "external-secrets"])
run(["kubectl", "rollout", "status", "deployment/external-secrets",
     "-n", "external-secrets", "--timeout=120s"])

# ── Phase 4: AWS Secrets Manager secret ──────────────────────────────────────

header("Phase 4: Ensuring Secrets Manager secret has correct JSON structure...")

secret_exists = run_ok(["aws", "secretsmanager", "describe-secret",
                         "--secret-id", DB_SECRET_ID, "--region", REGION])

def _prompt_and_store_secret():
    print(f"Enter credentials to store at {DB_SECRET_ID}:")
    db_user = input("  DB_USERNAME [admin]: ").strip() or "admin"
    db_pass  = getpass.getpass("  DB_PASSWORD: ")
    secret_value = json.dumps({"DB_USERNAME": db_user, "DB_PASSWORD": db_pass})
    return secret_value

if not secret_exists:
    print(f"Secret '{DB_SECRET_ID}' does not exist — creating it...")
    secret_value = _prompt_and_store_secret()
    run(["aws", "secretsmanager", "create-secret",
         "--name", DB_SECRET_ID, "--region", REGION,
         "--secret-string", secret_value])
    print(f"✅ Secret '{DB_SECRET_ID}' created.")
else:
    raw = capture(["aws", "secretsmanager", "get-secret-value",
                   "--secret-id", DB_SECRET_ID, "--region", REGION,
                   "--query", "SecretString", "--output", "text"])
    try:
        parsed = json.loads(raw)
        missing = [k for k in ("DB_USERNAME", "DB_PASSWORD") if k not in parsed]
        if missing:
            print(f"⚠️  Secret is missing keys: {missing} — updating...")
            secret_value = _prompt_and_store_secret()
            run(["aws", "secretsmanager", "put-secret-value",
                 "--secret-id", DB_SECRET_ID, "--region", REGION,
                 "--secret-string", secret_value])
        else:
            print(f"✅ Secret has correct keys: {list(parsed.keys())}")
    except (json.JSONDecodeError, TypeError):
        print(f"⚠️  Secret value is not valid JSON — overwriting...")
        secret_value = _prompt_and_store_secret()
        run(["aws", "secretsmanager", "put-secret-value",
             "--secret-id", DB_SECRET_ID, "--region", REGION,
             "--secret-string", secret_value])

# ── Phase 5: ArgoCD application configuration ─────────────────────────────────
# ArgoCD is installed by Terraform (modules/eks-addons). Apply the Application
# manifest and configure the server secret key.

header("Phase 5: Configuring ArgoCD application...")

header("Waiting for ArgoCD server to be Available (installed by Terraform)...")
run(["kubectl", "wait", "deployment", "argocd-server",
     "-n", "argocd", "--for=condition=Available", "--timeout=300s"])

header("Patching argocd-secret (server.secretkey)...")
generated_key = secrets_mod.token_hex(32)
patch = f'{{"stringData":{{"server.secretkey":"{generated_key}"}}}}'
run(["kubectl", "-n", "argocd", "patch", "secret", "argocd-secret", "-p", patch])

header("Applying ArgoCD Application manifest...")
app_manifest = os.path.join(os.path.dirname(__file__), "k8s", "argocd", "application.yaml")
if os.path.exists(app_manifest):
    run(["kubectl", "apply", "-f", app_manifest])
else:
    print(f"⚠️  {app_manifest} not found — skipping.")

header("Restarting ArgoCD controllers...")
for dep in ("argocd-dex-server", "argocd-applicationset-controller"):
    run(["kubectl", "rollout", "restart", f"deployment/{dep}", "-n", "argocd"])

time.sleep(10)
run(["kubectl", "annotate", "application", "bookstore",
     "-n", "argocd", "argocd.argoproj.io/refresh=hard", "--overwrite"], check=False)

# ── Phase 6: Clear kubectl cache + force ESO resync ──────────────────────────

header("Phase 6: Clearing kubectl discovery cache...")
cache_path = os.path.expandvars(r"%USERPROFILE%\.kube\cache")
if os.path.exists(cache_path):
    shutil.rmtree(cache_path, ignore_errors=True)
    print("✅ kubectl cache cleared.")

print("Waiting 20s for ESO to reconcile with new IRSA credentials...")
time.sleep(20)

ts = int(datetime.datetime.now().timestamp())
run(["kubectl", "annotate", "externalsecret", "db-secret",
     "-n", APP_NAMESPACE, f"force-sync={ts}", "--overwrite"], check=False)

# ── Phase 7: Database schema initialisation ───────────────────────────────────
#
# MySQL's docker-entrypoint-initdb.d only runs on first init (empty data dir).
# If the PVC already has data (e.g. after a crash/restart cycle that skipped init)
# the schema never gets created. This phase ensures it always exists, idempotently.
# Uses subprocess list args — no shell involved, so password special chars are safe.

header("Phase 7: Ensuring MySQL schema exists...")

print("Waiting for mysql-0 to be Ready (up to 10 min)...")
_mysql_ready = False
for _attempt in range(40):
    _status = capture(["kubectl", "get", "pod", "mysql-0", "-n", APP_NAMESPACE,
                        "-o", "jsonpath={.status.conditions[?(@.type=='Ready')].status}"])
    if _status == "True":
        print("✅ mysql-0 is Ready.")
        _mysql_ready = True
        break
    print(f"  mysql-0 not ready yet — retrying in 15s ({_attempt + 1}/40)...")
    sys.stdout.flush()
    time.sleep(15)

if not _mysql_ready:
    print("⚠️  mysql-0 did not become Ready within 10 min — skipping DB init.")
    print("   Re-run the script after MySQL starts, or run manually:")
    print("   kubectl exec -i -n bookstore mysql-0 -- mysql -uroot -p<pass> < k8s/database/init.sql")
else:
    _pw_b64 = capture(["kubectl", "get", "secret", "db-secret",
                        "-n", APP_NAMESPACE,
                        "-o", "jsonpath={.data.DB_PASSWORD}"])
    if not _pw_b64:
        print("⚠️  db-secret not found — skipping DB init. ESO may not have synced yet.")
    else:
        _db_password = base64.b64decode(_pw_b64).decode()

        _init_sql = (
            f"CREATE DATABASE IF NOT EXISTS `{DB_NAME}`;\n"
            f"USE `{DB_NAME}`;\n"
            "CREATE TABLE IF NOT EXISTS books (\n"
            "  id     INT NOT NULL AUTO_INCREMENT,\n"
            "  title  VARCHAR(300) NOT NULL,\n"
            "  `desc` VARCHAR(500) NOT NULL,\n"
            "  price  FLOAT NOT NULL,\n"
            "  cover  VARCHAR(500) NOT NULL,\n"
            "  PRIMARY KEY (id)\n"
            ");\n"
            "INSERT IGNORE INTO books (title, `desc`, price, cover) VALUES\n"
            "  ('The Great Gatsby', 'A novel by F. Scott Fitzgerald', 12.99,\n"
            "   'https://covers.openlibrary.org/b/id/8432472-L.jpg'),\n"
            "  ('To Kill a Mockingbird', 'A novel by Harper Lee', 10.99,\n"
            "   'https://covers.openlibrary.org/b/id/8810494-L.jpg');\n"
        )

        print(f"Running schema init on database '{DB_NAME}'...")
        _result = subprocess.run(
            ["kubectl", "exec", "-i", "-n", APP_NAMESPACE, "mysql-0", "--",
             "mysql", "-uroot", f"-p{_db_password}"],
            input=_init_sql,
            capture_output=True,
            text=True,
        )
        _stderr = _result.stderr or ""
        if _result.returncode == 0 or (_result.returncode != 0 and "ERROR" not in _stderr):
            print(f"✅ Database '{DB_NAME}' and table 'books' ready.")
        else:
            print(f"⚠️  DB init returned errors:\n{_stderr[:400]}")
            print("   Check MySQL logs: kubectl logs -n bookstore mysql-0")

# ── Phase 8: Summary + Route53 reminder ──────────────────────────────────────

header("Phase 8: Bootstrap Summary")

print("\n--- Cluster Nodes ---")
run(["kubectl", "get", "nodes"])

print("\n--- Platform pods ---")
run(["kubectl", "get", "pods", "--all-namespaces",
     "--field-selector=metadata.namespace!=kube-system"])

print("\n--- ExternalSecret status ---")
run(["kubectl", "get", "externalsecret", "-n", APP_NAMESPACE], check=False)

# Print the NLB hostname — user must update Route53 A records to this value
print("\n--- Load Balancer (IMPORTANT: update Route53 A records) ---")
lb_hostname = ""
for _ in range(12):          # wait up to 2 min for NLB hostname
    lb_hostname = capture(["kubectl", "get", "svc", "ingress-nginx-controller",
                            "-n", "ingress-nginx",
                            "-o", "jsonpath={.status.loadBalancer.ingress[0].hostname}"])
    if lb_hostname:
        break
    print("  Waiting for NLB hostname...")
    time.sleep(10)

if lb_hostname:
    frontend_host = f"bookstore.{DOMAIN}"
    backend_host  = f"api.bookstore.{DOMAIN}"
    print(f"""
  ⚠️  The ingress load balancer hostname has CHANGED.
  Update these Route53 records in the public hosted zone for {DOMAIN}:

    Record                        Type    Value
    ────────────────────────────  ──────  ──────────────────────────────────────
    {frontend_host}.              A       ALIAS → {lb_hostname}
    {backend_host}.               A       ALIAS → {lb_hostname}

  AWS Console path:
    Route 53 → Hosted zones → {DOMAIN} → Edit each A record → Alias to NLB

  NOTE: Both records must point to the SAME NLB hostname.
        *.{DOMAIN} wildcard is NOT sufficient — api.bookstore.{DOMAIN}
        is two levels deep and won't match a single-level wildcard.
""")
else:
    print("  NLB hostname not yet available. Check later:")
    print("  kubectl get svc ingress-nginx-controller -n ingress-nginx")

print(f"""
  Key resource ARNs for reference:
    IRSA role (external-secrets):  arn:aws:iam::{account_id}:role/{IRSA_ROLE_NAME}
    GitHub OIDC role (CI/CD):      arn:aws:iam::{account_id}:role/bookstore-github-oidc-role
    DB secret:                     {DB_SECRET_ID}
""")

print("🎉 Bootstrap complete! ArgoCD will sync within 3 minutes.")
print("   Monitor: kubectl get pods -n bookstore -w")
