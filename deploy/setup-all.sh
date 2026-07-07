#!/usr/bin/env bash
# setup-all.sh — run the full HTTPS + custom-domain setup in one command.
#
# Orchestrates the individual scripts in the correct order:
#   1. (optional) deploy-aws.sh      — upload the site to S3           (--deploy)
#   2. setup-cloudfront.sh           — create the CloudFront distribution
#   3. setup-domain.sh               — attach the custom domain (cert + DNS)
#
# It is safe to re-run: if config.yaml already has a distribution ID, step 2 is
# skipped (use --force to create a new one instead). Relevant flags are passed
# through to the underlying scripts.
#
# Configuration priority: CLI > env > config.yaml > default.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
Usage: setup-all.sh [options]

Run the full HTTPS + custom-domain setup end to end.

Options:
  -d, --domain NAME       Custom domain to attach (default: from config.yaml)
  -b, --bucket NAME       S3 bucket name
  -r, --region REGION     AWS region of the bucket
  -p, --profile NAME      AWS CLI named profile
      --deploy            Upload the site to S3 first (deploy-aws.sh)
      --no-domain         Stop after CloudFront; do not attach a domain
      --keep-public       Do not lock down the bucket in the CloudFront step
      --force             Create a new distribution even if one already exists
      --wait              Wait until everything finishes deploying (5-15 min)
  -h, --help              Show this help

Configuration priority: CLI flag > env var (TACHYON_*) > deploy/config.yaml > default.
EOF
}

CLI_DOMAIN="" CLI_BUCKET="" CLI_REGION="" CLI_PROFILE=""
DO_DEPLOY=0 DO_DOMAIN=1 KEEP_PUBLIC=0 FORCE=0 WAIT=0
while [ $# -gt 0 ]; do
  case "$1" in
    -d|--domain)  CLI_DOMAIN="$2"; shift 2;;
    -b|--bucket)  CLI_BUCKET="$2"; shift 2;;
    -r|--region)  CLI_REGION="$2"; shift 2;;
    -p|--profile) CLI_PROFILE="$2"; shift 2;;
    --deploy)     DO_DEPLOY=1; shift;;
    --no-domain)  DO_DOMAIN=0; shift;;
    --keep-public) KEEP_PUBLIC=1; shift;;
    --force)      FORCE=1; shift;;
    --wait)       WAIT=1; shift;;
    -h|--help)    usage; exit 0;;
    *) die "Unknown option: $1 (see --help)";;
  esac
done

# Build common pass-through flags.
COMMON_FLAGS=()
[ -n "$CLI_BUCKET" ]  && COMMON_FLAGS+=(--bucket "$CLI_BUCKET")
[ -n "$CLI_REGION" ]  && COMMON_FLAGS+=(--region "$CLI_REGION")
[ -n "$CLI_PROFILE" ] && COMMON_FLAGS+=(--profile "$CLI_PROFILE")

# ---- 1. Optional deploy ----------------------------------------------------
if [ "$DO_DEPLOY" -eq 1 ]; then
  log "== Step: upload site to S3 =="
  "${SCRIPT_DIR}/deploy-aws.sh" "${COMMON_FLAGS[@]}"
fi

# ---- 2. CloudFront (skip if a distribution already exists) -----------------
EXISTING_DIST="$(yaml_get cloudfront_distribution_id)"
if [ -n "$EXISTING_DIST" ] && [ "$FORCE" -eq 0 ]; then
  log "== Step: CloudFront — distribution $EXISTING_DIST already configured, skipping (use --force to recreate) =="
else
  log "== Step: create CloudFront distribution =="
  CF_FLAGS=("${COMMON_FLAGS[@]}")
  [ "$KEEP_PUBLIC" -eq 1 ] && CF_FLAGS+=(--keep-public)
  [ "$FORCE" -eq 1 ]       && CF_FLAGS+=(--force)
  # If we are not attaching a domain, honor --wait here; otherwise the domain
  # step (which redeploys the distribution) will do the final wait.
  [ "$WAIT" -eq 1 ] && [ "$DO_DOMAIN" -eq 0 ] && CF_FLAGS+=(--wait)
  "${SCRIPT_DIR}/setup-cloudfront.sh" "${CF_FLAGS[@]}"
fi

# ---- 3. Custom domain ------------------------------------------------------
if [ "$DO_DOMAIN" -eq 1 ]; then
  log "== Step: attach custom domain =="
  DOMAIN_FLAGS=()
  [ -n "$CLI_PROFILE" ] && DOMAIN_FLAGS+=(--profile "$CLI_PROFILE")
  [ -n "$CLI_DOMAIN" ]  && DOMAIN_FLAGS+=(--domain "$CLI_DOMAIN")
  [ "$WAIT" -eq 1 ]     && DOMAIN_FLAGS+=(--wait)
  "${SCRIPT_DIR}/setup-domain.sh" "${DOMAIN_FLAGS[@]}"
fi

echo
log "All done."
