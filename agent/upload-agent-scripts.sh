#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Render config.runtime.json from config.template.json + a local .env file, then
# publish the mutable agent files to S3. The .env file is never uploaded.
#
# Requirements: awscli, python3, and AWS credentials for the target account.
#
# Usage:
#   cp .env.example .env
#   # Edit .env with values for your environment.
#   ./upload-agent-scripts.sh
#   ./upload-agent-scripts.sh --no-config   # upload only record-agent.ps1
#   ./upload-agent-scripts.sh --render-only # render and validate; do not upload
#
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${CONFIG_TEMPLATE:-$DIR/config.template.json}"
ENV_FILE="${ENV_FILE:-$DIR/.env}"
RUNTIME_CONFIG="${RUNTIME_CONFIG:-$DIR/config.runtime.json}"
UPLOAD_CONFIG=true
RENDER_ONLY=false

for arg in "$@"; do
  case "$arg" in
    --no-config) UPLOAD_CONFIG=false ;;
    --render-only) RENDER_ONLY=true ;;
    *) echo "ERROR: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

[ -f "$TEMPLATE" ] || { echo "ERROR: config template not found at $TEMPLATE" >&2; exit 1; }
[ -f "$ENV_FILE" ] || {
  echo "ERROR: local environment file not found at $ENV_FILE" >&2
  echo "Create it with: cp '$DIR/.env.example' '$DIR/.env'" >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required" >&2; exit 1; }

python3 - "$TEMPLATE" "$ENV_FILE" "$RUNTIME_CONFIG" <<'PY'
import json
import os
import re
import sys
from pathlib import Path

template_path, env_path, output_path = map(Path, sys.argv[1:])
name_pattern = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
placeholder_pattern = re.compile(r"^\$\{([A-Za-z_][A-Za-z0-9_]*)\}$")


def load_dotenv(path):
    values = {}
    for number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        key, separator, value = line.partition("=")
        key = key.strip()
        if not separator or not name_pattern.fullmatch(key):
            raise SystemExit(f"ERROR: invalid .env entry at {path}:{number}")
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        values[key] = value
    return values


def coerce(raw):
    lowered = raw.lower()
    if lowered == "true":
        return True
    if lowered == "false":
        return False
    if re.fullmatch(r"-?(0|[1-9][0-9]*)", raw):
        return int(raw)
    if re.fullmatch(r"-?(0|[1-9][0-9]*)\.[0-9]+", raw):
        return float(raw)
    return raw


dotenv = load_dotenv(env_path)
values = {**dotenv, **{key: value for key, value in os.environ.items() if key.startswith("WSREC_")}}
missing = set()


def resolve(value):
    if isinstance(value, dict):
        return {key: resolve(item) for key, item in value.items()}
    if isinstance(value, list):
        return [resolve(item) for item in value]
    if isinstance(value, str):
        match = placeholder_pattern.fullmatch(value)
        if match:
            name = match.group(1)
            if name not in values:
                missing.add(name)
                return value
            return coerce(values[name])
    return value


template = json.loads(template_path.read_text(encoding="utf-8"))
rendered = resolve(template)
if missing:
    raise SystemExit("ERROR: missing required variables: " + ", ".join(sorted(missing)))

expected_types = {
    "s3Bucket": str,
    "region": str,
    "ffmpegPath": str,
    "awsPath": str,
    "awsProfile": str,
    "scriptsPrefix": str,
    "localDir": str,
    "psexecPath": str,
    "frameRate": int,
    "segmentSeconds": int,
    "idleThresholdSeconds": int,
    "pollSeconds": int,
    "quietSeconds": int,
    "sseKms": bool,
    "kmsKeyId": str,
}
for key, expected_type in expected_types.items():
    if key not in rendered:
        raise SystemExit(f"ERROR: rendered config is missing {key}")
    if type(rendered[key]) is not expected_type:
        raise SystemExit(f"ERROR: {key} must be {expected_type.__name__}, got {type(rendered[key]).__name__}")

for key in ("s3Bucket", "region", "ffmpegPath", "awsPath", "awsProfile", "scriptsPrefix", "localDir", "psexecPath"):
    if not rendered[key].strip():
        raise SystemExit(f"ERROR: {key} must not be empty")
for key in ("frameRate", "segmentSeconds", "idleThresholdSeconds", "pollSeconds", "quietSeconds"):
    if rendered[key] <= 0:
        raise SystemExit(f"ERROR: {key} must be greater than zero")

output_path.write_text(json.dumps(rendered, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
os.chmod(output_path, 0o600)
print(f"Rendered and validated {output_path}")
PY

read_key() {
  python3 - "$RUNTIME_CONFIG" "$1" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle).get(sys.argv[2], "")
if isinstance(value, bool):
    print(str(value).lower())
else:
    print(value)
PY
}

BUCKET="$(read_key s3Bucket)"
REGION="$(read_key region)"
PREFIX="$(read_key scriptsPrefix)"
[ -n "$PREFIX" ] || PREFIX="agent-scripts"

if $RENDER_ONLY; then
  echo "Render-only validation complete; no files were uploaded."
  exit 0
fi

command -v aws >/dev/null 2>&1 || { echo "ERROR: AWS CLI is required for upload" >&2; exit 1; }

SSE_ARGS=()
if [ "$(read_key sseKms)" = "true" ]; then
  KMS_KEY="$(read_key kmsKeyId)"
  SSE_ARGS=(--sse aws:kms)
  [ -n "$KMS_KEY" ] && SSE_ARGS+=(--sse-kms-key-id "$KMS_KEY")
fi

DEST="s3://$BUCKET/$PREFIX"
echo "Publishing agent scripts to $DEST/ (region $REGION)"

echo "  -> record-agent.ps1"
aws s3 cp "$DIR/record-agent.ps1" "$DEST/record-agent.ps1" \
  --region "$REGION" "${SSE_ARGS[@]}" --only-show-errors

if $UPLOAD_CONFIG; then
  echo "  -> config.json (rendered from local .env; .env is not uploaded)"
  aws s3 cp "$RUNTIME_CONFIG" "$DEST/config.json" \
    --region "$REGION" "${SSE_ARGS[@]}" --only-show-errors
else
  echo "  (skipped runtime config upload)"
fi

echo "Done. Verify:"
echo "  aws s3api list-objects-v2 --bucket '$BUCKET' --prefix '$PREFIX/' --region '$REGION'"
