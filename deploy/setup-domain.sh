#!/usr/bin/env bash
# setup-domain.sh — attach a custom domain (e.g. tachyon.org) to the site's
# CloudFront distribution, with an HTTPS certificate and Route 53 DNS.
#
# Prerequisites:
#   * setup-cloudfront.sh has been run (config.yaml has cloudfront_distribution_id)
#   * the domain's public hosted zone already exists in Route 53
#
# What it does:
#   1. Requests (or reuses) an ACM certificate in us-east-1 for the domain and
#      its www subdomain, validated via DNS.
#   2. Creates the DNS validation records in Route 53 and waits for issuance.
#   3. Adds the domain names as aliases on the distribution and attaches the
#      certificate (SNI, TLS 1.2+).
#   4. Creates Route 53 alias A/AAAA records pointing the domain at CloudFront.
#
# ACM certificates for CloudFront MUST live in us-east-1 regardless of the
# bucket's region; this script uses us-east-1 for all certificate operations.
#
# Configuration priority: CLI > env > config.yaml > default.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# CloudFront's fixed hosted-zone ID for alias records (global constant).
CF_HOSTED_ZONE_ID="Z2FDTNDATAQYW2"
ACM_REGION="us-east-1"

usage() {
  cat <<'EOF'
Usage: setup-domain.sh [options]

Attach a custom domain to the site's CloudFront distribution.

Options:
  -d, --domain NAME        Apex domain to attach (default: from config.yaml)
      --no-www             Do not also attach the www.<domain> subdomain
      --distribution ID     CloudFront distribution ID (default: from config.yaml)
      --hosted-zone-id ID   Route 53 hosted zone ID (default: auto-detect by domain)
  -p, --profile NAME        AWS CLI named profile
      --wait                Wait until the distribution finishes deploying
  -h, --help                Show this help

Configuration priority: CLI flag > env var (TACHYON_*) > deploy/config.yaml > default.
EOF
}

CLI_DOMAIN="" CLI_PROFILE="" CLI_DIST="" CLI_ZONE=""
WWW=1 WAIT=0
while [ $# -gt 0 ]; do
  case "$1" in
    -d|--domain)       CLI_DOMAIN="$2"; shift 2;;
    --no-www)          WWW=0; shift;;
    --distribution)    CLI_DIST="$2"; shift 2;;
    --hosted-zone-id)  CLI_ZONE="$2"; shift 2;;
    -p|--profile)      CLI_PROFILE="$2"; shift 2;;
    --wait)            WAIT=1; shift;;
    -h|--help)         usage; exit 0;;
    *) die "Unknown option: $1 (see --help)";;
  esac
done

DOMAIN="$(resolve domain "$CLI_DOMAIN" "tachyon-research.org")"
PROFILE="$(resolve profile "$CLI_PROFILE" "")"
DIST_ID="$(resolve cloudfront_distribution_id "$CLI_DIST" "")"

[ -n "$DIST_ID" ] || die "No CloudFront distribution configured. Run setup-cloudfront.sh first (or pass --distribution)."
command -v python3 >/dev/null 2>&1 || die "python3 is required for this script."

# aws with the configured profile; region is passed explicitly per call.
awsp() {
  local a=(aws)
  [ -n "${PROFILE:-}" ] && a+=(--profile "$PROFILE")
  "${a[@]}" "$@"
}

# Build the list of domain names to cover.
NAMES=("$DOMAIN")
[ "$WWW" -eq 1 ] && NAMES+=("www.${DOMAIN}")

require_aws
log "Domain:        $DOMAIN"
log "Names:         ${NAMES[*]}"
log "Distribution:  $DIST_ID"

# ---- 0. Locate the Route 53 hosted zone ------------------------------------
if [ -n "$CLI_ZONE" ]; then
  ZONE_ID="$CLI_ZONE"
else
  ZONE_ID="$(awsp route53 list-hosted-zones-by-name --dns-name "$DOMAIN" \
    --query "HostedZones[?Name=='${DOMAIN}.'].Id | [0]" --output text)"
  ZONE_ID="${ZONE_ID##*/}"   # strip the /hostedzone/ prefix
fi
[ -n "$ZONE_ID" ] && [ "$ZONE_ID" != "None" ] || die "No Route 53 hosted zone found for $DOMAIN."
log "Hosted zone:   $ZONE_ID"

# ---- 1. Request or reuse an ACM certificate (us-east-1) --------------------
log "Ensuring ACM certificate in $ACM_REGION..."
CERT_ARN="$(awsp acm list-certificates --region "$ACM_REGION" \
  --query "CertificateSummaryList[?DomainName=='${DOMAIN}'].CertificateArn | [0]" \
  --output text 2>/dev/null || true)"

if [ -z "$CERT_ARN" ] || [ "$CERT_ARN" = "None" ]; then
  SAN_ARGS=()
  [ "$WWW" -eq 1 ] && SAN_ARGS=(--subject-alternative-names "www.${DOMAIN}")
  CERT_ARN="$(awsp acm request-certificate --region "$ACM_REGION" \
    --domain-name "$DOMAIN" "${SAN_ARGS[@]}" \
    --validation-method DNS \
    --idempotency-token "tachyon$(date +%Y%m%d)" \
    --query CertificateArn --output text)"
  log "Requested certificate: $CERT_ARN"
else
  log "Reusing certificate: $CERT_ARN"
fi

# ---- 2. Create DNS validation records, then wait for issuance --------------
log "Fetching DNS validation records..."
VALIDATION=""
for _ in 1 2 3 4 5 6; do
  VALIDATION="$(awsp acm describe-certificate --region "$ACM_REGION" \
    --certificate-arn "$CERT_ARN" \
    --query "Certificate.DomainValidationOptions[].ResourceRecord.[Name,Type,Value]" \
    --output text 2>/dev/null || true)"
  [ -n "$VALIDATION" ] && [ "$VALIDATION" != "None" ] && break
  sleep 5
done
[ -n "$VALIDATION" ] || die "Could not read certificate validation records."

# Build one UPSERT change batch for the (deduped) validation CNAMEs.
# The records are written to a temp file so python reads them from a path
# (its stdin is occupied by the heredoc program text).
VAL_FILE="$(mktemp)"
printf '%s\n' "$VALIDATION" | sort -u > "$VAL_FILE"
CHANGE_BATCH="$(VAL_FILE="$VAL_FILE" python3 - <<'PY'
import os, json
changes = []
seen = set()
with open(os.environ["VAL_FILE"]) as fh:
    for line in fh:
        parts = line.rstrip("\n").split("\t")
        if len(parts) != 3:
            continue
        name, rtype, value = parts
        if not name or (name, value) in seen:
            continue
        seen.add((name, value))
        changes.append({
            "Action": "UPSERT",
            "ResourceRecordSet": {
                "Name": name, "Type": rtype, "TTL": 300,
                "ResourceRecords": [{"Value": value}],
            },
        })
print(json.dumps({"Comment": "ACM validation for site", "Changes": changes}))
PY
)"
rm -f "$VAL_FILE"
log "Creating validation records in Route 53..."
awsp route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --change-batch "$CHANGE_BATCH" >/dev/null

log "Waiting for the certificate to be issued (usually a few minutes)..."
awsp acm wait certificate-validated --region "$ACM_REGION" --certificate-arn "$CERT_ARN"
log "Certificate issued."

# ---- 3. Attach aliases + certificate to the distribution -------------------
log "Updating the distribution with aliases and certificate..."
CFG_JSON="$(mktemp)"; NEW_CFG="$(mktemp)"
awsp cloudfront get-distribution-config --id "$DIST_ID" > "$CFG_JSON"

ETAG="$(python3 - "$CFG_JSON" "$NEW_CFG" "$CERT_ARN" "${NAMES[@]}" <<'PY'
import sys, json
cfg_path, out_path, cert_arn, *names = sys.argv[1:]
with open(cfg_path) as f:
    data = json.load(f)
etag = data["ETag"]
dc = data["DistributionConfig"]
dc["Aliases"] = {"Quantity": len(names), "Items": names}
dc["ViewerCertificate"] = {
    "ACMCertificateArn": cert_arn,
    "SSLSupportMethod": "sni-only",
    "MinimumProtocolVersion": "TLSv1.2_2021",
    "Certificate": cert_arn,
    "CertificateSource": "acm",
}
with open(out_path, "w") as f:
    json.dump(dc, f)
print(etag)
PY
)"
awsp cloudfront update-distribution --id "$DIST_ID" \
  --distribution-config "file://$NEW_CFG" --if-match "$ETAG" >/dev/null
rm -f "$CFG_JSON" "$NEW_CFG"
log "Distribution updated."

# ---- 4. Point the domain at CloudFront with Route 53 alias records ---------
CF_DOMAIN="$(awsp cloudfront get-distribution --id "$DIST_ID" \
  --query 'Distribution.DomainName' --output text)"
log "Creating Route 53 alias records -> $CF_DOMAIN ..."

ALIAS_BATCH="$(python3 - "$CF_DOMAIN" "$CF_HOSTED_ZONE_ID" "${NAMES[@]}" <<'PY'
import sys, json
cf_domain, cf_zone, *names = sys.argv[1:]
changes = []
for name in names:
    for rtype in ("A", "AAAA"):
        changes.append({
            "Action": "UPSERT",
            "ResourceRecordSet": {
                "Name": name,
                "Type": rtype,
                "AliasTarget": {
                    "HostedZoneId": cf_zone,
                    "DNSName": cf_domain,
                    "EvaluateTargetHealth": False,
                },
            },
        })
print(json.dumps({"Comment": "Point domain at CloudFront", "Changes": changes}))
PY
)"
awsp route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --change-batch "$ALIAS_BATCH" >/dev/null
log "DNS alias records created."

# ---- 5. Optionally wait for deployment -------------------------------------
if [ "$WAIT" -eq 1 ]; then
  log "Waiting for the distribution to finish deploying (5-15 min)..."
  awsp cloudfront wait distribution-deployed --id "$DIST_ID"
  log "Distribution deployed."
fi

echo
log "Custom domain setup complete."
for n in "${NAMES[@]}"; do log "  https://${n}"; done
[ "$WAIT" -eq 0 ] && warn "Allow a few minutes for the distribution to redeploy and DNS to propagate."
