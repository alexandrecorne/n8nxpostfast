#!/usr/bin/env bash
# Upload a local video to PostFast and print the media `key` to paste into
# the "PostFast Media Key" property of the corresponding Notion short.
#
# PostFast's /file/get-signed-upload-urls returns a short-lived S3 URL
# (5 min) and a key like "video/<uuid>.mp4". We PUT the bytes to S3 then
# hand the key back.
#
# Required env var:
#   POSTFAST_API_KEY   raw PostFast key (pf-api-key header value)
#
# Optional env var:
#   CONTENT_TYPE       defaults to video/mp4
#
# Usage:
#   export POSTFAST_API_KEY="tuk7TzAI..."
#   bash scripts/upload-video.sh path/to/short-42.mp4
#
# For image uploads pass CONTENT_TYPE=image/jpeg or image/png.

set -euo pipefail

FILE="${1:-}"
CONTENT_TYPE="${CONTENT_TYPE:-video/mp4}"

die() { echo "error: $*" >&2; exit 1; }

[[ -n "${FILE}" ]]                 || die "usage: bash scripts/upload-video.sh <path/to/file>"
[[ -f "${FILE}" ]]                 || die "file not found: ${FILE}"
[[ -n "${POSTFAST_API_KEY:-}" ]]   || die "POSTFAST_API_KEY is not set."
command -v curl >/dev/null 2>&1    || die "curl is required."
command -v jq >/dev/null 2>&1      || die "jq is required."

# PostFast limits: 250 MB for video, 10 MB for images.
FILE_BYTES="$(stat -c '%s' "${FILE}" 2>/dev/null || stat -f '%z' "${FILE}")"
MAX_BYTES=$(( 250 * 1024 * 1024 ))
if [[ "${CONTENT_TYPE}" == image/* ]]; then
  MAX_BYTES=$(( 10 * 1024 * 1024 ))
fi
if (( FILE_BYTES > MAX_BYTES )); then
  die "file is ${FILE_BYTES} bytes, exceeds PostFast limit of ${MAX_BYTES} bytes for content-type ${CONTENT_TYPE}."
fi

# 1. Ask PostFast for a signed URL.
echo "→ Requesting signed upload URL for ${FILE} (${CONTENT_TYPE}, ${FILE_BYTES} bytes)..."
RESP_TMP="$(mktemp)"
RESP_CODE="$(curl -sS -o "${RESP_TMP}" -w '%{http_code}' \
  -X POST "https://api.postfa.st/file/get-signed-upload-urls" \
  -H "pf-api-key: ${POSTFAST_API_KEY}" \
  -H "Content-Type: application/json" \
  --data "$(jq -n --arg ct "${CONTENT_TYPE}" '{contentType: $ct, count: 1}')" || echo 000)"

if [[ "${RESP_CODE}" != "200" && "${RESP_CODE}" != "201" ]]; then
  echo "  ✗ PostFast returned HTTP ${RESP_CODE}:" >&2
  cat "${RESP_TMP}" >&2
  rm -f "${RESP_TMP}"
  die "failed to get signed URL."
fi

# Response is either an array of {signedUrl, key} or {data: [...]}. Handle both.
SIGNED_URL="$(jq -r '(if type=="array" then .[0] else (.data[0] // .[0]) end) | .signedUrl // .url // empty' "${RESP_TMP}")"
KEY="$(jq -r '(if type=="array" then .[0] else (.data[0] // .[0]) end) | .key // empty' "${RESP_TMP}")"
rm -f "${RESP_TMP}"

[[ -n "${SIGNED_URL}" ]] || die "no signedUrl in response."
[[ -n "${KEY}" ]]        || die "no key in response."

echo "  ✓ got key=${KEY}"

# 2. PUT the file to the signed S3 URL.
echo "→ Uploading to S3..."
UPLOAD_TMP="$(mktemp)"
UPLOAD_CODE="$(curl -sS -o "${UPLOAD_TMP}" -w '%{http_code}' \
  -X PUT \
  -H "Content-Type: ${CONTENT_TYPE}" \
  --data-binary "@${FILE}" \
  "${SIGNED_URL}" || echo 000)"

if [[ "${UPLOAD_CODE}" != "200" ]]; then
  echo "  ✗ S3 upload returned HTTP ${UPLOAD_CODE}:" >&2
  head -c 500 "${UPLOAD_TMP}" >&2
  echo "" >&2
  rm -f "${UPLOAD_TMP}"
  die "upload failed."
fi
rm -f "${UPLOAD_TMP}"

echo ""
echo "✓ Upload complete."
echo ""
echo "Paste this into the 'PostFast Media Key' column of the corresponding"
echo "Notion short (https://www.notion.so/34028224657180d8951bcc555a2c66b8):"
echo ""
echo "  ${KEY}"
echo ""
