#!/usr/bin/env bash
# setup-cloudfront.sh — put a CloudFront distribution in front of the
# Tachyon Resilient Modeling S3 bucket for HTTPS and CDN caching.
#
# This switches the site to the AWS-recommended secure pattern:
#   * an Origin Access Control (OAC) so only CloudFront can read the bucket
#   * the bucket is locked down (public-read removed, public access re-blocked)
#   * HTTPS via the default *.cloudfront.net certificate (no custom domain needed)
#   * viewer requests are redirected to HTTPS, compressed, and cached
#   * 403/404 from the origin are served as /error.html (your 404 page)
#
# After it succeeds, the site is reachable ONLY through the CloudFront domain it
# prints; the plain S3 website endpoint will stop serving (by design). The new
# distribution ID is written back into config.yaml so `deploy-aws.sh`
# automatically invalidates the CDN cache on future deploys.
#
# Run `setup-aws.sh` first. Configuration priority: CLI > env > config.yaml > default.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# AWS-managed cache policy "CachingOptimized" (stable, well-known ID).
MANAGED_CACHING_OPTIMIZED="658327ea-f89d-4fab-a63d-7e88639e58f6"

usage() {
  cat <<'EOF'
Usage: setup-cloudfront.sh [options]

Create a CloudFront distribution (with OAC) in front of the site's S3 bucket.

Options:
  -b, --bucket NAME       S3 bucket name
  -r, --region REGION     AWS region of the bucket
  -p, --profile NAME      AWS CLI named profile
      --keep-public        Do NOT lock down the bucket after wiring up OAC
      --wait               Wait until the distribution is fully deployed (5-15 min)
      --force              Create a new distribution even if config.yaml already has one
  -h, --help               Show this help

Configuration priority: CLI flag > env var (TACHYON_*) > deploy/config.yaml > default.
EOF
}

CLI_BUCKET="" CLI_REGION="" CLI_PROFILE=""
LOCKDOWN=1 WAIT=0 FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    -b|--bucket)  CLI_BUCKET="$2"; shift 2;;
    -r|--region)  CLI_REGION="$2"; shift 2;;
    -p|--profile) CLI_PROFILE="$2"; shift 2;;
    --keep-public) LOCKDOWN=0; shift;;
    --wait)       WAIT=1; shift;;
    --force)      FORCE=1; shift;;
    -h|--help)    usage; exit 0;;
    *) die "Unknown option: $1 (see --help)";;
  esac
done

BUCKET="$(resolve bucket "$CLI_BUCKET" "")"
REGION="$(resolve region "$CLI_REGION" "us-west-2")"
PROFILE="$(resolve profile "$CLI_PROFILE" "")"
EXISTING_DIST="$(yaml_get cloudfront_distribution_id)"

[ -n "$BUCKET" ] || die "No bucket name configured. Set 'bucket' in config.yaml or pass --bucket."

if [ -n "$EXISTING_DIST" ] && [ "$FORCE" -eq 0 ]; then
  die "config.yaml already has cloudfront_distribution_id=$EXISTING_DIST. Use --force to create another."
fi

require_aws
ACCOUNT_ID="$(aws_cli sts get-caller-identity --query Account --output text)"
ORIGIN_DOMAIN="${BUCKET}.s3.${REGION}.amazonaws.com"
OAC_NAME="${BUCKET}-oac"

log "Bucket:  $BUCKET"
log "Region:  $REGION"
log "Account: $ACCOUNT_ID"
log "Origin:  $ORIGIN_DOMAIN"

# ---- 1. Origin Access Control (reuse if one with this name already exists) --
log "Ensuring Origin Access Control '$OAC_NAME'..."
OAC_ID="$(aws_cli cloudfront list-origin-access-controls \
  --query "OriginAccessControlList.Items[?Name=='${OAC_NAME}'].Id | [0]" \
  --output text 2>/dev/null || true)"

if [ -z "$OAC_ID" ] || [ "$OAC_ID" = "None" ]; then
  OAC_CONFIG="$(mktemp)"
  cat > "$OAC_CONFIG" <<EOF
{
  "Name": "${OAC_NAME}",
  "Description": "OAC for Tachyon Resilient Modeling site",
  "SigningProtocol": "sigv4",
  "SigningBehavior": "always",
  "OriginAccessControlOriginType": "s3"
}
EOF
  OAC_ID="$(aws_cli cloudfront create-origin-access-control \
    --origin-access-control-config "file://$OAC_CONFIG" \
    --query 'OriginAccessControl.Id' --output text)"
  rm -f "$OAC_CONFIG"
  log "Created OAC: $OAC_ID"
else
  log "Reusing existing OAC: $OAC_ID"
fi

# ---- 2. CloudFront distribution --------------------------------------------
log "Creating CloudFront distribution..."
DIST_CONFIG="$(mktemp)"
CALLER_REF="tachyon-$(date +%s)"
cat > "$DIST_CONFIG" <<EOF
{
  "CallerReference": "${CALLER_REF}",
  "Comment": "Tachyon Resilient Modeling website",
  "Enabled": true,
  "DefaultRootObject": "index.html",
  "PriceClass": "PriceClass_100",
  "Origins": {
    "Quantity": 1,
    "Items": [
      {
        "Id": "s3-${BUCKET}",
        "DomainName": "${ORIGIN_DOMAIN}",
        "OriginAccessControlId": "${OAC_ID}",
        "S3OriginConfig": { "OriginAccessIdentity": "" }
      }
    ]
  },
  "DefaultCacheBehavior": {
    "TargetOriginId": "s3-${BUCKET}",
    "ViewerProtocolPolicy": "redirect-to-https",
    "Compress": true,
    "AllowedMethods": {
      "Quantity": 2,
      "Items": ["GET", "HEAD"],
      "CachedMethods": { "Quantity": 2, "Items": ["GET", "HEAD"] }
    },
    "CachePolicyId": "${MANAGED_CACHING_OPTIMIZED}"
  },
  "CustomErrorResponses": {
    "Quantity": 2,
    "Items": [
      { "ErrorCode": 403, "ResponsePagePath": "/error.html", "ResponseCode": "404", "ErrorCachingMinTTL": 60 },
      { "ErrorCode": 404, "ResponsePagePath": "/error.html", "ResponseCode": "404", "ErrorCachingMinTTL": 60 }
    ]
  },
  "ViewerCertificate": { "CloudFrontDefaultCertificate": true }
}
EOF

# Create once and pull all three fields as tab-separated text (no jq needed).
DIST_ID="" DIST_DOMAIN="" DIST_ARN=""
IFS=$'\t' read -r DIST_ID DIST_DOMAIN DIST_ARN < <(
  aws_cli cloudfront create-distribution \
    --distribution-config "file://$DIST_CONFIG" \
    --query '[Distribution.Id, Distribution.DomainName, Distribution.ARN]' \
    --output text
)
rm -f "$DIST_CONFIG"
[ -n "$DIST_ID" ] && [ "$DIST_ID" != "None" ] || die "Failed to create distribution."
log "Created distribution: $DIST_ID"
log "Domain: $DIST_DOMAIN"

# ---- 3. Bucket policy: allow only this distribution (via OAC) ---------------
log "Granting the distribution read access to the bucket..."
POLICY_FILE="$(mktemp)"
cat > "$POLICY_FILE" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowCloudFrontServicePrincipal",
      "Effect": "Allow",
      "Principal": { "Service": "cloudfront.amazonaws.com" },
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::${BUCKET}/*",
      "Condition": { "StringEquals": { "AWS:SourceArn": "${DIST_ARN}" } }
    }
  ]
}
EOF
aws_cli s3api put-bucket-policy --bucket "$BUCKET" --policy "file://$POLICY_FILE"
rm -f "$POLICY_FILE"

# ---- 4. Lock down the bucket (unless --keep-public) ------------------------
if [ "$LOCKDOWN" -eq 1 ]; then
  log "Locking down the bucket (removing public access)..."
  aws_cli s3api put-public-access-block --bucket "$BUCKET" \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=false,RestrictPublicBuckets=true"
  # Note: BlockPublicPolicy stays false so the OAC service-principal policy is
  # allowed; RestrictPublicBuckets=true blocks anonymous/cross-account access.
else
  warn "Leaving bucket public (--keep-public)."
fi

# ---- 5. Persist the distribution ID into config.yaml -----------------------
log "Writing distribution ID into config.yaml..."
if grep -q '^cloudfront_distribution_id:' "$CONFIG_FILE"; then
  # Portable in-place edit (macOS/BSD and GNU sed).
  sed -i.bak "s|^cloudfront_distribution_id:.*|cloudfront_distribution_id: ${DIST_ID}|" "$CONFIG_FILE"
  rm -f "${CONFIG_FILE}.bak"
else
  printf 'cloudfront_distribution_id: %s\n' "$DIST_ID" >> "$CONFIG_FILE"
fi

# ---- 6. Optionally wait for deployment -------------------------------------
if [ "$WAIT" -eq 1 ]; then
  log "Waiting for distribution to deploy (this can take 5-15 minutes)..."
  aws_cli cloudfront wait distribution-deployed --id "$DIST_ID"
  log "Distribution is deployed."
fi

echo
log "CloudFront setup complete."
log "HTTPS URL: https://${DIST_DOMAIN}"
log "Distribution ID: ${DIST_ID} (saved to config.yaml)"
[ "$WAIT" -eq 0 ] && warn "The distribution is still deploying (5-15 min). The URL will 5xx until it finishes."
log "Future deploys: ./deploy-aws.sh  (will now auto-invalidate the CDN cache)"
