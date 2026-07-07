#!/usr/bin/env bash
# setup-aws.sh — one-time provisioning of the S3 bucket that hosts the
# Tachyon Resilient Modeling website.
#
# Creates the bucket (if needed), enables static website hosting, and applies a
# public-read bucket policy so the site is reachable over the S3 website
# endpoint. Safe to re-run: existing resources are updated in place.
#
# Configuration priority: CLI flag > env var > deploy/config.yaml > default.
# See `--help` for options.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
Usage: setup-aws.sh [options]

Provision the S3 bucket for static website hosting.

Options:
  -b, --bucket NAME       S3 bucket name (globally unique)
  -r, --region REGION     AWS region
  -p, --profile NAME      AWS CLI named profile
      --index FILE         Index document (default: index.html)
      --error FILE         Error document (default: error.html)
      --no-public          Do not apply a public-read policy (use with CloudFront/OAC)
  -h, --help               Show this help

Configuration priority: CLI flag > env var (TACHYON_*) > deploy/config.yaml > default.
EOF
}

CLI_BUCKET="" CLI_REGION="" CLI_PROFILE="" CLI_INDEX="" CLI_ERROR=""
PUBLIC=1
while [ $# -gt 0 ]; do
  case "$1" in
    -b|--bucket)  CLI_BUCKET="$2"; shift 2;;
    -r|--region)  CLI_REGION="$2"; shift 2;;
    -p|--profile) CLI_PROFILE="$2"; shift 2;;
    --index)      CLI_INDEX="$2"; shift 2;;
    --error)      CLI_ERROR="$2"; shift 2;;
    --no-public)  PUBLIC=0; shift;;
    -h|--help)    usage; exit 0;;
    *) die "Unknown option: $1 (see --help)";;
  esac
done

BUCKET="$(resolve bucket "$CLI_BUCKET" "")"
REGION="$(resolve region "$CLI_REGION" "us-west-2")"
PROFILE="$(resolve profile "$CLI_PROFILE" "")"
INDEX="$(resolve index_document "$CLI_INDEX" "index.html")"
ERROR="$(resolve error_document "$CLI_ERROR" "error.html")"

[ -n "$BUCKET" ] || die "No bucket name configured. Set 'bucket' in config.yaml or pass --bucket."

require_aws
log "Bucket:  $BUCKET"
log "Region:  $REGION"
log "Profile: ${PROFILE:-(default)}"

# ---- create bucket ---------------------------------------------------------
if aws_cli s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  log "Bucket already exists — updating configuration."
else
  log "Creating bucket..."
  if [ "$REGION" = "us-east-1" ]; then
    aws_cli s3api create-bucket --bucket "$BUCKET"
  else
    aws_cli s3api create-bucket --bucket "$BUCKET" \
      --create-bucket-configuration "LocationConstraint=$REGION"
  fi
fi

# ---- static website hosting ------------------------------------------------
log "Enabling static website hosting (index=$INDEX, error=$ERROR)..."
aws_cli s3 website "s3://$BUCKET" --index-document "$INDEX" --error-document "$ERROR"

# ---- public access ---------------------------------------------------------
if [ "$PUBLIC" -eq 1 ]; then
  log "Applying public-read bucket policy..."
  aws_cli s3api put-public-access-block --bucket "$BUCKET" \
    --public-access-block-configuration \
    "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false"

  POLICY_FILE="$(mktemp)"
  trap 'rm -f "$POLICY_FILE"' EXIT
  cat > "$POLICY_FILE" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PublicReadGetObject",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::${BUCKET}/*"
    }
  ]
}
EOF
  aws_cli s3api put-bucket-policy --bucket "$BUCKET" --policy "file://$POLICY_FILE"
else
  warn "Skipping public policy (--no-public). Configure CloudFront + OAC for access."
fi

ENDPOINT="http://${BUCKET}.s3-website-${REGION}.amazonaws.com"
[ "$REGION" = "us-east-1" ] && ENDPOINT="http://${BUCKET}.s3-website-us-east-1.amazonaws.com"
log "Setup complete."
log "Website endpoint: $ENDPOINT"
log "Next: ./deploy/deploy-aws.sh"
