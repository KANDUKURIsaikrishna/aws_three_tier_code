#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# init-domain.sh
#
# Run ONCE per domain, ever — not once per apply/destroy cycle.
#
# Terraform (modules/route53) reads the public hosted zone via a
# `data "aws_route53_zone"` lookup, it does NOT create or destroy it. That's
# deliberate: a Route53 zone gets 4 brand-new, randomly-assigned nameservers
# every time it's created, so if Terraform owned it, every `terraform
# destroy` + fresh `apply` would silently break your registrar's delegation
# until someone noticed the domain stopped resolving and manually redid the
# NS handoff (see docs/TROUBLESHOOTING.md OBS-058 for the full incident this
# script exists to stop repeating).
#
# What it does:
#   1. Reads DOMAIN from config.env (or an explicit CLI arg)
#   2. Creates the public Route53 hosted zone if it doesn't already exist
#      (idempotent — safe to re-run any time, e.g. after a fresh checkout)
#   3. Prints the zone's 4 NS values for you to set at your registrar
#
# After running this once and updating your registrar, every future
# `terraform apply`/`terraform destroy` cycle leaves this zone alone.
#
# Usage:
#   chmod +x scripts/init-domain.sh
#   ./scripts/init-domain.sh [domain]
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

DOMAIN="${1:-}"
if [[ -z "${DOMAIN}" && -f "${REPO_ROOT}/config.env" ]]; then
  DOMAIN="$(grep -E '^DOMAIN=' "${REPO_ROOT}/config.env" | tail -1 | cut -d= -f2- | tr -d '"'"'"' \r')"
fi

if [[ -z "${DOMAIN}" ]]; then
  echo "Usage: ./scripts/init-domain.sh <domain>  (or set DOMAIN in config.env)" >&2
  exit 1
fi

echo ""
echo "Domain : ${DOMAIN}"
echo ""

# ── Find an existing public zone for this exact domain, if any ────────────────
# list-hosted-zones-by-name can also return zones for unrelated parent/child
# domains that sort near this name alphabetically, so filter strictly on an
# exact Name match ("<domain>." with the trailing dot Route53 always adds)
# and PrivateZone == false -- the private RDS zone (modules/route53's
# rds_private) uses the same account and could otherwise collide by name.
EXISTING_ZONE_ID="$(aws route53 list-hosted-zones-by-name \
  --dns-name "${DOMAIN}" \
  --query "HostedZones[?Name=='${DOMAIN}.' && Config.PrivateZone==\`false\`].Id | [0]" \
  --output text)"

if [[ -n "${EXISTING_ZONE_ID}" && "${EXISTING_ZONE_ID}" != "None" ]]; then
  echo "[skip] Public hosted zone already exists: ${EXISTING_ZONE_ID}"
  ZONE_ID="${EXISTING_ZONE_ID}"
else
  echo "[create] Public hosted zone..."
  ZONE_ID="$(aws route53 create-hosted-zone \
    --name "${DOMAIN}" \
    --caller-reference "init-domain-$(date +%s)" \
    --query "HostedZone.Id" \
    --output text)"
  echo "[ok] Created ${ZONE_ID}"
fi

NAME_SERVERS="$(aws route53 get-hosted-zone --id "${ZONE_ID}" --query "DelegationSet.NameServers" --output text)"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "One-time step: set these 4 nameservers at your domain registrar"
echo "(GoDaddy, Namecheap, etc. — wherever ${DOMAIN} is registered):"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
for ns in ${NAME_SERVERS}; do
  echo "  ${ns}"
done
echo ""
echo "Propagation to public resolvers can take anywhere from a few minutes to"
echo "longer, depending on the registrar and previous record TTLs. Do this"
echo "BEFORE running 'terraform apply' for the ingress/ACM layer, not after —"
echo "otherwise the apply will sit on 'aws_acm_certificate_validation.ingress:"
echo "Still creating...' until it does."
echo ""
echo "Once set, this is a one-time step for this domain -- future"
echo "terraform apply / terraform destroy cycles never touch this zone."
