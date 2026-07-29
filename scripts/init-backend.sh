#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# init-backend.sh
#
# Run ONCE before the first `terraform apply` in a fresh checkout, or
# whenever versions.tf has empty bucket/dynamodb_table strings.
#
# What it does:
#   1. Reads your AWS Account ID (no hardcoding needed)
#   2. Creates the S3 bucket + DynamoDB lock table if they don't exist yet
#   3. Writes the correct bucket name into versions.tf automatically
#   4. Runs `terraform init` (or `terraform init -reconfigure` if already init'd)
#
# Usage:
#   chmod +x scripts/init-backend.sh
#   ./scripts/init-backend.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REGION="${1:-us-west-1}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="bookstore-terraform-state-${ACCOUNT_ID}"
TABLE="terraform-state-lock"
VERSIONS_TF="$(dirname "$0")/../versions.tf"

echo ""
echo "Account : ${ACCOUNT_ID}"
echo "Region  : ${REGION}"
echo "Bucket  : ${BUCKET}"
echo "Table   : ${TABLE}"
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

# ── 2. DynamoDB lock table ─────────────────────────────────────────────────────
if aws dynamodb describe-table \
     --table-name "${TABLE}" \
     --region "${REGION}" \
     --query "Table.TableName" \
     --output text 2>/dev/null | grep -q "${TABLE}"; then
  echo "[skip] DynamoDB lock table already exists."
else
  echo "[create] DynamoDB lock table..."
  aws dynamodb create-table \
    --table-name "${TABLE}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "${REGION}"
  echo "[ok] DynamoDB lock table created."
fi

# ── 3. Patch versions.tf with correct bucket name ─────────────────────────────
echo ""
echo "[patch] Writing bucket name into versions.tf..."

# Replace whatever is between the bucket quotes (including empty string)
# Uses BSD-compatible sed (macOS) — the -i '' form.
sed -i '' \
  "s|bucket[[:space:]]*=[[:space:]]*\"[^\"]*\"|bucket         = \"${BUCKET}\"|" \
  "${VERSIONS_TF}"

sed -i '' \
  "s|dynamodb_table[[:space:]]*=[[:space:]]*\"[^\"]*\"|dynamodb_table = \"${TABLE}\"|" \
  "${VERSIONS_TF}"

echo "[ok] versions.tf updated."
echo ""
grep -A 8 'backend "s3"' "${VERSIONS_TF}"

# ── 4. terraform init ──────────────────────────────────────────────────────────
echo ""
echo "[init] Running terraform init..."
cd "$(dirname "$0")/.."

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
