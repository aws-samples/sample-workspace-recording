#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# upload-agent-scripts.sh
# Publish the mutable agent scripts to S3 so the in-image bootstrap (session-start.ps1)
# can pull the latest at each session start - no image rebuild needed.
#
# Reads s3Bucket / region / scriptsPrefix straight from config.json so it never drifts.
# Requires: awscli + python3, and AWS credentials for the target account.
#
# Usage:
#   ./upload-agent-scripts.sh            # upload record-agent.ps1 AND config.json
#   ./upload-agent-scripts.sh --no-config  # upload only record-agent.ps1
#
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$DIR/config.json"

[ -f "$CONFIG" ] || { echo "ERROR: config.json not found at $CONFIG" >&2; exit 1; }

# --- read bucket/region/prefix from config.json (single source of truth) ---
read_key() { python3 -c "import json,sys;print(json.load(open('$CONFIG')).get('$1',''))"; }
BUCKET="$(read_key s3Bucket)"
REGION="$(read_key region)"
PREFIX="$(read_key scriptsPrefix)"
[ -n "$PREFIX" ] || PREFIX="agent-scripts"

[ -n "$BUCKET" ] || { echo "ERROR: s3Bucket empty in config.json" >&2; exit 1; }
[ -n "$REGION" ] || { echo "ERROR: region empty in config.json" >&2; exit 1; }

# SSE-KMS: match the bucket default encryption. Use the CMK if config.json specifies one.
KMS_KEY="$(read_key kmsKeyId)"
SSE_ARGS=(--sse aws:kms)
[ -n "$KMS_KEY" ] && SSE_ARGS+=(--sse-kms-key-id "$KMS_KEY")

DEST="s3://$BUCKET/$PREFIX"
echo "Publishing agent scripts to $DEST/  (region $REGION)"

echo "  -> record-agent.ps1"
aws s3 cp "$DIR/record-agent.ps1" "$DEST/record-agent.ps1" \
  --region "$REGION" "${SSE_ARGS[@]}" --only-show-errors

if [ "${1:-}" != "--no-config" ]; then
  echo "  -> config.json"
  aws s3 cp "$CONFIG" "$DEST/config.json" \
    --region "$REGION" "${SSE_ARGS[@]}" --only-show-errors
else
  echo "  (skipped config.json)"
fi

echo "Done. Verify:"
echo "  aws s3 ls $DEST/ --region $REGION"
