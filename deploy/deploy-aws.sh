#!/usr/bin/env bash
# deploy-aws.sh — upload the Tachyon Resilient Modeling website to S3.
#
# Syncs the local site directory to the configured S3 bucket (removing files
# that no longer exist locally) and, if a CloudFront distribution is configured,
# issues a cache invalidation.
#
# Configuration priority: CLI flag > env var > deploy/config.yaml > default.
# See `--help` for options.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
Usage: deploy-aws.sh [options]

Upload the website to the configured S3 bucket.

Options:
  -b, --bucket NAME       S3 bucket name
  -r, --region REGION     AWS region
  -p, --profile NAME      AWS CLI named profile
  -s, --source DIR        Local site directory (default: web)
      --distribution ID    CloudFront distribution ID to invalidate
      --dry-run            Show what would change without uploading
  -h, --help               Show this help

Configuration priority: CLI flag > env var (TACHYON_*) > deploy/config.yaml > default.
EOF
}

CLI_BUCKET="" CLI_REGION="" CLI_PROFILE="" CLI_SOURCE="" CLI_DIST=""
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    -b|--bucket)       CLI_BUCKET="$2"; shift 2;;
    -r|--region)       CLI_REGION="$2"; shift 2;;
    -p|--profile)      CLI_PROFILE="$2"; shift 2;;
    -s|--source)       CLI_SOURCE="$2"; shift 2;;
    --distribution)    CLI_DIST="$2"; shift 2;;
    --dry-run)         DRY_RUN=1; shift;;
    -h|--help)         usage; exit 0;;
    *) die "Unknown option: $1 (see --help)";;
  esac
done

BUCKET="$(resolve bucket "$CLI_BUCKET" "")"
REGION="$(resolve region "$CLI_REGION" "us-west-2")"
PROFILE="$(resolve profile "$CLI_PROFILE" "")"
SOURCE="$(resolve source_dir "$CLI_SOURCE" "web")"
DIST="$(resolve cloudfront_distribution_id "$CLI_DIST" "")"

[ -n "$BUCKET" ] || die "No bucket name configured. Set 'bucket' in config.yaml or pass --bucket."

# Resolve the source dir relative to the repo root if it is not absolute.
case "$SOURCE" in
  /*) SRC_PATH="$SOURCE";;
  *)  SRC_PATH="${REPO_ROOT}/${SOURCE}";;
esac
[ -d "$SRC_PATH" ] || die "Source directory not found: $SRC_PATH"

require_aws
log "Source:  $SRC_PATH"
log "Bucket:  s3://$BUCKET"
log "Region:  $REGION"
log "Profile: ${PROFILE:-(default)}"

SYNC_OPTS=(--delete)
[ "$DRY_RUN" -eq 1 ] && SYNC_OPTS+=(--dryrun) && warn "DRY RUN — no changes will be made."

# Long cache for static assets, short cache for HTML so content updates appear.
log "Uploading static assets (css, js, images)..."
aws_cli s3 sync "$SRC_PATH" "s3://$BUCKET" "${SYNC_OPTS[@]}" \
  --exclude "*.html" \
  --cache-control "public,max-age=604800"

log "Uploading HTML..."
aws_cli s3 sync "$SRC_PATH" "s3://$BUCKET" "${SYNC_OPTS[@]}" \
  --exclude "*" --include "*.html" \
  --content-type "text/html; charset=utf-8" \
  --cache-control "public,max-age=300"

# ---- CloudFront invalidation ----------------------------------------------
if [ -n "$DIST" ] && [ "$DRY_RUN" -eq 0 ]; then
  log "Invalidating CloudFront distribution $DIST..."
  aws_cli cloudfront create-invalidation --distribution-id "$DIST" --paths "/*" >/dev/null
  log "Invalidation submitted."
elif [ -n "$DIST" ]; then
  warn "Skipping CloudFront invalidation (dry run)."
fi

ENDPOINT="http://${BUCKET}.s3-website-${REGION}.amazonaws.com"
log "Deploy complete."
[ "$DRY_RUN" -eq 0 ] && log "Live at: $ENDPOINT"
