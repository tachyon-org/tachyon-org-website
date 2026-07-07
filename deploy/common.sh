#!/usr/bin/env bash
# Shared helpers for the Tachyon Resilient Modeling deployment scripts.
#
# Provides:
#   - a minimal parser for the flat deploy/config.yaml
#   - config resolution with the priority: CLI flag > env var > config file > default
#   - AWS CLI wrappers that honor the selected profile/region
#
# This file is meant to be sourced, not executed directly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.yaml"

# ---- logging ---------------------------------------------------------------
log()  { printf '\033[0;36m[deploy]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# ---- minimal flat-YAML reader ---------------------------------------------
# Reads a top-level "key: value" pair from config.yaml. Strips inline comments
# and surrounding quotes. Only supports the flat schema used by this project.
yaml_get() {
  local key="$1"
  [ -f "$CONFIG_FILE" ] || return 0
  sed -n "s/^${key}:[[:space:]]*//p" "$CONFIG_FILE" \
    | head -n1 \
    | sed 's/[[:space:]]*#.*$//' \
    | sed 's/^["'\'']//; s/["'\'']$//' \
    | sed 's/[[:space:]]*$//'
}

# Resolve a config value using: CLI override > env var > config file > default.
#   resolve <key> <cli_value> <default>
# The matching env var is TACHYON_<UPPERCASE_KEY>.
resolve() {
  local key="$1" cli_value="${2:-}" default="${3:-}"
  local env_name="TACHYON_$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')"
  local env_value="${!env_name:-}"

  if [ -n "$cli_value" ]; then
    printf '%s' "$cli_value"
  elif [ -n "$env_value" ]; then
    printf '%s' "$env_value"
  else
    local file_value
    file_value="$(yaml_get "$key")"
    if [ -n "$file_value" ]; then
      printf '%s' "$file_value"
    else
      printf '%s' "$default"
    fi
  fi
}

# ---- AWS wrapper -----------------------------------------------------------
# Usage: aws_cli s3 sync ...   (adds --profile/--region when configured)
aws_cli() {
  local args=(aws)
  [ -n "${PROFILE:-}" ] && args+=(--profile "$PROFILE")
  [ -n "${REGION:-}" ]  && args+=(--region "$REGION")
  "${args[@]}" "$@"
}

require_aws() {
  command -v aws >/dev/null 2>&1 || die "aws CLI not found. Install it: https://aws.amazon.com/cli/"
  aws_cli sts get-caller-identity >/dev/null 2>&1 \
    || die "AWS credentials not configured or invalid. Run 'aws configure'."
}
