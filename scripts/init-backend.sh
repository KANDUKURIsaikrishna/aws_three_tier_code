#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# init-backend.sh
#
# Run ONCE before the first `terraform apply` in a fresh checkout, or
# whenever versions.tf has an empty bucket string.
#
# What it does:
#   1. Reads your AWS Account ID (no hardcoding needed)
#   2. Creates the S3 bucket if it doesn't exist yet (state locking is native
#      S3 conditional-write locking via use_lockfile -- no DynamoDB table)
#   3. Writes the correct bucket name AND region into versions.tf automatically
#   4. Runs `terraform init` (or `terraform init -reconfigure` if already init'd)
#
# Region resolution, in priority order:
#   1. An explicit CLI arg: ./scripts/init-backend.sh us-west-2
#   2. AWS_REGION from config.env, if config.env exists (same file
#      scripts/configure.py reads -- run this AFTER filling in config.env so
#      the backend's region and terraform.tfvars' region can't drift apart)
#   3. us-west-1, if neither of the above is set
#
# Usage:
#   chmod +x scripts/init-backend.sh
#   ./scripts/init-backend.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_ENV_REGION=""
if [[ -f "${REPO_ROOT}/config.env" ]]; then
  CONFIG_ENV_REGION="$(grep -E '^AWS_REGION=' "${REPO_ROOT}/config.env" | tail -1 | cut -d= -f2- | tr -d '"'"'"' \r')"
fi

REGION="${1:-${CONFIG_ENV_REGION:-us-west-1}}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="bookstore-terraform-state-${ACCOUNT_ID}"
VERSIONS_TF="${REPO_ROOT}/versions.tf"

echo ""
echo "Account : ${ACCOUNT_ID}"
echo "Region  : ${REGION}"
echo "Bucket  : ${BUCKET}"
echo ""

# ── 1. S3 bucket ──────────────────────────────────────────────────────────────
if aws s3api head-bucket --bucket "${BUCKET}" --region "${REGION}" 2>/dev/null; then
  echo "[skip] S3 bucket already exists."
else
  echo "[create] S3 bucket..."
  if [[ "${REGION}" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "${BUCKET}" --region "${REGION}"
  else
    aws s3api create-bucket \
      --bucket "${BUCKET}" \
      --region "${REGION}" \
      --create-bucket-configuration LocationConstraint="${REGION}"
  fi

  aws s3api put-bucket-versioning \
    --bucket "${BUCKET}" \
    --versioning-configuration Status=Enabled

  aws s3api put-bucket-encryption \
    --bucket "${BUCKET}" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'

  aws s3api put-public-access-block \
    --bucket "${BUCKET}" \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

  echo "[ok] S3 bucket created."
fi

# ── 2. Patch versions.tf with correct bucket name and region ──────────────────
echo ""
echo "[patch] Writing bucket name and region into versions.tf..."

# Replace whatever is between the bucket quotes (including empty string).
# `sed -i ''` (BSD/macOS) and `sed -i` (GNU/Linux) take incompatible -i
# syntax -- writing to a temp file and moving it back works identically on
# both, so this doesn't silently break for anyone not on macOS.
TMP_VERSIONS_TF="$(mktemp)"
sed \
  "s|bucket[[:space:]]*=[[:space:]]*\"[^\"]*\"|bucket         = \"${BUCKET}\"|" \
  "${VERSIONS_TF}" > "${TMP_VERSIONS_TF}"
mv "${TMP_VERSIONS_TF}" "${VERSIONS_TF}"

# The backend block's own `region` field -- previously left hardcoded to
# whatever the checked-in template said, completely disconnected from
# config.env's AWS_REGION or this script's own resolved $REGION. Terraform
# backend blocks can't reference variables at all (a real HCL limitation,
# not an oversight), so this field can only ever be kept correct by exactly
# this kind of external patch -- same reason bucket is patched above, not
# left as a `var.foo` reference.
TMP_VERSIONS_TF="$(mktemp)"
sed \
  "s|region[[:space:]]*=[[:space:]]*\"[^\"]*\"|region               = \"${REGION}\"|" \
  "${VERSIONS_TF}" > "${TMP_VERSIONS_TF}"
mv "${TMP_VERSIONS_TF}" "${VERSIONS_TF}"

echo "[ok] versions.tf updated."
echo ""
grep -A 8 'backend "s3"' "${VERSIONS_TF}"

# ── 3. terraform init ──────────────────────────────────────────────────────────
echo ""
echo "[init] Running terraform init..."
cd "${REPO_ROOT}"

if [[ -d ".terraform" ]]; then
  terraform init -reconfigure
else
  terraform init
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Backend ready. Run:"
echo "  terraform plan"
echo "  terraform apply"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
