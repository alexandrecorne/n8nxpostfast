#!/usr/bin/env bash
# Deploy the EO Shorts Auto-Publisher workflow to an n8n instance.
#
# The n8n public API exposes POST /credentials (create) and DELETE
# /credentials/:id but NO list/GET endpoint, so the script can't
# resolve existing credentials by name. Instead it either (a) creates
# a fresh PostFast credential and uses the returned id, or (b) reuses
# an id you pass in via env var.
#
# Required env vars:
#   N8N_API_KEY       JWT from n8n UI → Settings → n8n API → Create API Key
#   POSTFAST_API_KEY  raw PostFast key (becomes the pf-api-key header value)
#   NOTION_CRED_ID    id of the "Notion API" credential created in the UI.
#                     Get it by opening the credential in the UI: the URL
#                     ends with /home/credentials/<uuid>. Copy <uuid>.
#
# Optional env vars:
#   POSTFAST_CRED_ID   reuse an existing PostFast credential instead of
#                      creating a new one. Get it the same way as NOTION_CRED_ID.
#   N8N_BASE_URL       defaults to http://72.62.187.71:5678
#   N8N_PROJECT_ID     target n8n project (e.g. bnK2w5BUU8YLwyol)
#   TARGET_WORKFLOW_ID overwrite this specific workflow id
#   DEBUG=1            enable shell tracing
#
# Usage:
#   export N8N_API_KEY="eyJhbGciOi..."
#   export POSTFAST_API_KEY="tuk7TzAI..."
#   export NOTION_CRED_ID="<uuid from n8n UI>"
#   export N8N_PROJECT_ID="bnK2w5BUU8YLwyol"
#   export TARGET_WORKFLOW_ID="VztWOvTejsjBV4Vh8tL2o"
#   bash scripts/deploy-to-n8n.sh

set -euo pipefail
[[ "${DEBUG:-}" == "1" ]] && set -x

N8N_BASE_URL="${N8N_BASE_URL:-http://72.62.187.71:5678}"
N8N_PROJECT_ID="${N8N_PROJECT_ID:-}"
TARGET_WORKFLOW_ID="${TARGET_WORKFLOW_ID:-}"
POSTFAST_CRED_ID="${POSTFAST_CRED_ID:-}"
NOTION_CRED_ID="${NOTION_CRED_ID:-}"
POSTFAST_CRED_NAME="${POSTFAST_CRED_NAME:-PostFast API}"
WORKFLOW_FILE="$(cd "$(dirname "$0")/.." && pwd)/workflows/eo-shorts-auto-publisher.json"
WORKFLOW_NAME="EO Shorts Auto-Publisher"

die() { echo "error: $*" >&2; exit 1; }

# ---- Preflight --------------------------------------------------------------
[[ -n "${N8N_API_KEY:-}" ]]      || die "N8N_API_KEY is not set."
[[ -n "${POSTFAST_API_KEY:-}" ]] || die "POSTFAST_API_KEY is not set."
[[ -n "${NOTION_CRED_ID}" ]]     || die "NOTION_CRED_ID is not set. Open your 'Notion API' credential in the n8n UI and copy the UUID from the URL (/home/credentials/<uuid>)."
[[ -f "${WORKFLOW_FILE}" ]]      || die "workflow file not found: ${WORKFLOW_FILE}"
command -v jq >/dev/null 2>&1    || die "jq is required."
command -v curl >/dev/null 2>&1  || die "curl is required."

AUTH_HEADER="X-N8N-API-KEY: ${N8N_API_KEY}"

# ---- Connectivity + auth sanity check --------------------------------------
echo "→ Pinging n8n API at ${N8N_BASE_URL}..."
PING_TMP="$(mktemp)"
PING_CODE="$(curl -sS -o "${PING_TMP}" -w '%{http_code}' \
  -H "${AUTH_HEADER}" \
  -H "Accept: application/json" \
  "${N8N_BASE_URL}/api/v1/workflows?limit=1" || echo 000)"

if [[ "${PING_CODE}" != "200" ]]; then
  echo "  ✗ n8n API returned HTTP ${PING_CODE}:" >&2
  cat "${PING_TMP}" >&2
  echo "" >&2
  rm -f "${PING_TMP}"
  die "could not reach n8n API. Check N8N_BASE_URL and N8N_API_KEY."
fi
rm -f "${PING_TMP}"
echo "  ✓ API reachable and auth accepted."

# ---- 1. Resolve PostFast credential id -------------------------------------
if [[ -n "${POSTFAST_CRED_ID}" ]]; then
  echo "→ Reusing PostFast credential id=${POSTFAST_CRED_ID} (from env)."
else
  echo "→ Creating new '${POSTFAST_CRED_NAME}' credential via POST /credentials..."
  CREATE_BODY="$(jq -n \
    --arg name "${POSTFAST_CRED_NAME}" \
    --arg value "${POSTFAST_API_KEY}" \
    '{name: $name, type: "httpHeaderAuth", data: {name: "pf-api-key", value: $value}}')"

  CREATE_TMP="$(mktemp)"
  CREATE_CODE="$(curl -sS -o "${CREATE_TMP}" -w '%{http_code}' \
    -X POST \
    -H "${AUTH_HEADER}" \
    -H "Content-Type: application/json" \
    --data "${CREATE_BODY}" \
    "${N8N_BASE_URL}/api/v1/credentials" || echo 000)"

  if [[ "${CREATE_CODE}" == "200" || "${CREATE_CODE}" == "201" ]]; then
    POSTFAST_CRED_ID="$(jq -r '.id // .data.id // empty' "${CREATE_TMP}")"
    if [[ -z "${POSTFAST_CRED_ID}" ]]; then
      echo "  ✗ credential created but couldn't parse id from response:" >&2
      cat "${CREATE_TMP}" >&2
      rm -f "${CREATE_TMP}"
      die "unexpected response format."
    fi
    echo "  ✓ created credential id=${POSTFAST_CRED_ID}"
  else
    echo "  ✗ creation failed (HTTP ${CREATE_CODE}):" >&2
    cat "${CREATE_TMP}" >&2
    echo "" >&2
    rm -f "${CREATE_TMP}"
    cat <<EOF >&2

If the error mentions a duplicate credential (already exists), open the
existing PostFast credential in the n8n UI, copy the UUID from the URL
(${N8N_BASE_URL}/home/credentials/<uuid>), and re-run with:

  export POSTFAST_CRED_ID="<uuid>"

EOF
    exit 1
  fi
  rm -f "${CREATE_TMP}"
fi

# ---- 2. Build the workflow payload with resolved credential ids ------------
echo "→ Building workflow payload (substituting credential ids)..."
PAYLOAD="$(
  jq --arg pf "${POSTFAST_CRED_ID}" --arg no "${NOTION_CRED_ID}" '
    .nodes |= map(
      if (.credentials.httpHeaderAuth // null) != null then
        .credentials.httpHeaderAuth.id = $pf
      else . end
      | if (.credentials.notionApi // null) != null then
          .credentials.notionApi.id = $no
        else . end
    )
    | {name, nodes, connections, settings}
  ' "${WORKFLOW_FILE}"
)"

# Sanity check the substitution actually happened.
if echo "${PAYLOAD}" | grep -q "REPLACE_WITH_" ; then
  echo "  ✗ some credential placeholders were not substituted:" >&2
  echo "${PAYLOAD}" | grep "REPLACE_WITH_" >&2 || true
  die "placeholder leak. Check workflow JSON and env vars."
fi
echo "  ✓ payload ready."

# ---- 3. Create or overwrite the workflow -----------------------------------
EXISTING_ID="${TARGET_WORKFLOW_ID}"
if [[ -z "${EXISTING_ID}" ]]; then
  echo "→ Looking up any existing workflow named '${WORKFLOW_NAME}'..."
  LIST_TMP="$(mktemp)"
  LIST_CODE="$(curl -sS -o "${LIST_TMP}" -w '%{http_code}' \
    -H "${AUTH_HEADER}" -H "Accept: application/json" \
    "${N8N_BASE_URL}/api/v1/workflows?limit=250" || echo 000)"
  if [[ "${LIST_CODE}" == "200" ]]; then
    EXISTING_ID="$(
      jq -r --arg n "${WORKFLOW_NAME}" '
        (if type=="array" then . else (.data // []) end)
        | map(select(.name == $n)) | .[0].id // empty
      ' "${LIST_TMP}"
    )"
    [[ -n "${EXISTING_ID}" ]] && echo "  ✓ found existing workflow id=${EXISTING_ID}"
  else
    echo "  ! list returned HTTP ${LIST_CODE}, will attempt to create a new workflow" >&2
  fi
  rm -f "${LIST_TMP}"
fi

FRESHLY_CREATED="false"
WRITE_TMP="$(mktemp)"
if [[ -n "${EXISTING_ID}" ]]; then
  echo "→ Overwriting workflow id=${EXISTING_ID} (PUT)..."
  WRITE_CODE="$(curl -sS -o "${WRITE_TMP}" -w '%{http_code}' \
    -X PUT \
    -H "${AUTH_HEADER}" -H "Content-Type: application/json" \
    --data "${PAYLOAD}" \
    "${N8N_BASE_URL}/api/v1/workflows/${EXISTING_ID}" || echo 000)"
  NEW_ID="${EXISTING_ID}"
else
  echo "→ Creating new workflow (POST)..."
  WRITE_CODE="$(curl -sS -o "${WRITE_TMP}" -w '%{http_code}' \
    -X POST \
    -H "${AUTH_HEADER}" -H "Content-Type: application/json" \
    --data "${PAYLOAD}" \
    "${N8N_BASE_URL}/api/v1/workflows" || echo 000)"
  NEW_ID="$(jq -r '.id // .data.id // empty' "${WRITE_TMP}" 2>/dev/null || echo "")"
  FRESHLY_CREATED="true"
fi

if [[ "${WRITE_CODE}" != "200" && "${WRITE_CODE}" != "201" ]]; then
  echo "  ✗ workflow write failed (HTTP ${WRITE_CODE}):" >&2
  cat "${WRITE_TMP}" >&2
  rm -f "${WRITE_TMP}"
  die "deploy failed."
fi
jq '{id, name}' "${WRITE_TMP}" 2>/dev/null || cat "${WRITE_TMP}"
rm -f "${WRITE_TMP}"

# ---- 4. Best-effort project transfer ---------------------------------------
if [[ "${FRESHLY_CREATED}" == "true" && -n "${N8N_PROJECT_ID}" ]]; then
  echo "→ Transferring workflow ${NEW_ID} to project ${N8N_PROJECT_ID}..."
  TRANSFER_TMP="$(mktemp)"
  TRANSFER_BODY="$(jq -n --arg p "${N8N_PROJECT_ID}" '{destinationProjectId: $p}')"
  TRANSFER_CODE="$(curl -sS -o "${TRANSFER_TMP}" -w '%{http_code}' \
    -X PUT \
    -H "${AUTH_HEADER}" -H "Content-Type: application/json" \
    --data "${TRANSFER_BODY}" \
    "${N8N_BASE_URL}/api/v1/workflows/${NEW_ID}/transfer" || echo 000)"
  if [[ "${TRANSFER_CODE}" == "200" || "${TRANSFER_CODE}" == "204" ]]; then
    echo "  ✓ transferred."
  else
    echo "  ! transfer returned HTTP ${TRANSFER_CODE} (ignorable on Community edition):" >&2
    cat "${TRANSFER_TMP}" >&2
    echo "" >&2
  fi
  rm -f "${TRANSFER_TMP}"
fi

echo ""
echo "✓ Deployed. Open the workflow:"
echo "  ${N8N_BASE_URL}/workflow/${NEW_ID}"
echo ""
echo "Next steps:"
echo "  • Execute Workflow once on a test short."
echo "  • When green, toggle it Active (top-right)."
