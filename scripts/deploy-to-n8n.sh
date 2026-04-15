#!/usr/bin/env bash
# Deploy (or update) the EO Shorts Auto-Publisher workflow to an n8n instance.
#
# The script is idempotent and does everything it can automatically:
#   1. Creates/reuses a Header Auth credential named "PostFast API" (header
#      name: pf-api-key, value: $POSTFAST_API_KEY).
#   2. Looks up any existing credential named "Notion API".
#   3. Substitutes the two credential IDs into the workflow JSON template.
#   4. Creates or updates (PUT) the workflow. If TARGET_WORKFLOW_ID is set,
#      that specific workflow is overwritten so existing UI URLs keep working.
#   5. If N8N_PROJECT_ID is set AND a fresh workflow was created, transfers
#      it into that project.
#
# The workflow is NEVER activated automatically — flip the toggle in the UI
# once a manual run has validated end-to-end behavior.
#
# Required env vars:
#   N8N_API_KEY        — JWT from n8n UI: Settings → n8n API → Create API Key
#   POSTFAST_API_KEY   — raw PostFast API key (value for the pf-api-key header)
#
# Optional env vars:
#   N8N_BASE_URL       — defaults to http://72.62.187.71:5678
#   N8N_PROJECT_ID     — target n8n project (e.g. bnK2w5BUU8YLwyol)
#   TARGET_WORKFLOW_ID — overwrite this specific workflow id instead of
#                        looking up by name / creating a new one
#
# Usage:
#   export N8N_API_KEY="eyJhbGciOi..."
#   export POSTFAST_API_KEY="tuk7TzAI..."
#   export N8N_PROJECT_ID="bnK2w5BUU8YLwyol"
#   export TARGET_WORKFLOW_ID="VztWOvTejsjBV4Vh8tL2o"
#   bash scripts/deploy-to-n8n.sh

set -euo pipefail

N8N_BASE_URL="${N8N_BASE_URL:-http://72.62.187.71:5678}"
N8N_PROJECT_ID="${N8N_PROJECT_ID:-}"
TARGET_WORKFLOW_ID="${TARGET_WORKFLOW_ID:-}"
WORKFLOW_FILE="$(cd "$(dirname "$0")/.." && pwd)/workflows/eo-shorts-auto-publisher.json"
WORKFLOW_NAME="EO Shorts Auto-Publisher"
POSTFAST_CRED_NAME="PostFast API"
NOTION_CRED_NAME="Notion API"

die() { echo "error: $*" >&2; exit 1; }

# --- Preflight ---------------------------------------------------------------
[[ -n "${N8N_API_KEY:-}" ]]       || die "N8N_API_KEY is not set (create one at ${N8N_BASE_URL}/settings/api)."
[[ -n "${POSTFAST_API_KEY:-}" ]]  || die "POSTFAST_API_KEY is not set."
[[ -f "${WORKFLOW_FILE}" ]]       || die "workflow file not found: ${WORKFLOW_FILE}"
command -v jq >/dev/null 2>&1     || die "jq is required (install with: brew install jq  OR  apt-get install jq)."
command -v curl >/dev/null 2>&1   || die "curl is required."

AUTH_HEADER="X-N8N-API-KEY: ${N8N_API_KEY}"

# --- Helper: curl wrapper that surfaces body + status ------------------------
n8n_api() {
  local method="$1"; shift
  local path="$1"; shift
  local body="${1:-}"
  local tmp; tmp="$(mktemp)"
  local code
  if [[ -n "${body}" ]]; then
    code="$(curl -sS -o "${tmp}" -w '%{http_code}' \
      -X "${method}" \
      -H "${AUTH_HEADER}" \
      -H "Content-Type: application/json" \
      --data "${body}" \
      "${N8N_BASE_URL}${path}")"
  else
    code="$(curl -sS -o "${tmp}" -w '%{http_code}' \
      -X "${method}" \
      -H "${AUTH_HEADER}" \
      -H "Accept: application/json" \
      "${N8N_BASE_URL}${path}")"
  fi
  echo "${code}"
  cat "${tmp}"
  rm -f "${tmp}"
}

# --- 1. Resolve or create the PostFast credential ----------------------------
echo "→ Resolving '${POSTFAST_CRED_NAME}' credential..."
POSTFAST_CRED_ID="$(
  curl -fsSL -H "${AUTH_HEADER}" -H 'Accept: application/json' \
    "${N8N_BASE_URL}/api/v1/credentials" 2>/dev/null \
    | jq -r --arg n "${POSTFAST_CRED_NAME}" '
        (if type=="array" then . else (.data // []) end)
        | map(select(.name == $n)) | .[0].id // empty'
)"

if [[ -z "${POSTFAST_CRED_ID}" ]]; then
  echo "  ℹ not found, creating via API..."
  CREATE_BODY="$(jq -n \
    --arg name "${POSTFAST_CRED_NAME}" \
    --arg value "${POSTFAST_API_KEY}" \
    '{name: $name, type: "httpHeaderAuth", data: {name: "pf-api-key", value: $value}}')"
  RESULT="$(n8n_api POST "/api/v1/credentials" "${CREATE_BODY}")"
  STATUS="$(echo "${RESULT}" | head -n1)"
  PAYLOAD="$(echo "${RESULT}" | tail -n +2)"
  if [[ "${STATUS}" != "200" && "${STATUS}" != "201" ]]; then
    echo "${PAYLOAD}" >&2
    die "failed to create PostFast credential (HTTP ${STATUS})."
  fi
  POSTFAST_CRED_ID="$(echo "${PAYLOAD}" | jq -r '.id // .data.id')"
  [[ -n "${POSTFAST_CRED_ID}" && "${POSTFAST_CRED_ID}" != "null" ]] || { echo "${PAYLOAD}" >&2; die "could not parse new credential id."; }
  echo "  ✓ created credential id=${POSTFAST_CRED_ID}"
else
  echo "  ✓ using existing credential id=${POSTFAST_CRED_ID}"
fi

# --- 2. Resolve the Notion credential (manual creation required) -------------
echo "→ Resolving '${NOTION_CRED_NAME}' credential..."
NOTION_CRED_ID="$(
  curl -fsSL -H "${AUTH_HEADER}" -H 'Accept: application/json' \
    "${N8N_BASE_URL}/api/v1/credentials" 2>/dev/null \
    | jq -r --arg n "${NOTION_CRED_NAME}" '
        (if type=="array" then . else (.data // []) end)
        | map(select(.name == $n)) | .[0].id // empty'
)"

if [[ -z "${NOTION_CRED_ID}" ]]; then
  cat <<EOF >&2
  ✗ No '${NOTION_CRED_NAME}' credential found.
    Create one manually in the n8n UI:
      1. ${N8N_BASE_URL}/home/credentials → + Add credential
      2. Type: Notion API
      3. Name: ${NOTION_CRED_NAME}
      4. Internal Integration Secret from https://www.notion.so/my-integrations
      5. Connect the integration to the Shorts EO DB:
         https://www.notion.so/34028224657180d8951bcc555a2c66b8
         (⋯ menu → Connections → Connect to → your integration)
    Then re-run this script.
EOF
  exit 2
fi
echo "  ✓ using existing credential id=${NOTION_CRED_ID}"

# --- 3. Substitute credential IDs into the workflow JSON ---------------------
echo "→ Building workflow payload with resolved credential ids..."
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

# --- 4. Create or overwrite the workflow -------------------------------------
EXISTING_ID="${TARGET_WORKFLOW_ID}"
if [[ -z "${EXISTING_ID}" ]]; then
  echo "→ Checking whether '${WORKFLOW_NAME}' already exists..."
  EXISTING_ID="$(
    curl -fsSL -H "${AUTH_HEADER}" -H 'Accept: application/json' \
      "${N8N_BASE_URL}/api/v1/workflows" 2>/dev/null \
      | jq -r --arg n "${WORKFLOW_NAME}" '
          (if type=="array" then . else (.data // []) end)
          | map(select(.name == $n)) | .[0].id // empty'
  )"
fi

FRESHLY_CREATED="false"
if [[ -n "${EXISTING_ID}" ]]; then
  echo "→ Overwriting workflow id=${EXISTING_ID} (PUT)..."
  RESULT="$(n8n_api PUT "/api/v1/workflows/${EXISTING_ID}" "${PAYLOAD}")"
  STATUS="$(echo "${RESULT}" | head -n1)"
  RESPONSE="$(echo "${RESULT}" | tail -n +2)"
  if [[ "${STATUS}" != "200" ]]; then
    echo "${RESPONSE}" >&2
    die "workflow update failed (HTTP ${STATUS})."
  fi
  NEW_ID="${EXISTING_ID}"
else
  echo "→ Creating new workflow (POST)..."
  RESULT="$(n8n_api POST "/api/v1/workflows" "${PAYLOAD}")"
  STATUS="$(echo "${RESULT}" | head -n1)"
  RESPONSE="$(echo "${RESULT}" | tail -n +2)"
  if [[ "${STATUS}" != "200" && "${STATUS}" != "201" ]]; then
    echo "${RESPONSE}" >&2
    die "workflow creation failed (HTTP ${STATUS})."
  fi
  NEW_ID="$(echo "${RESPONSE}" | jq -r '.id // .data.id')"
  FRESHLY_CREATED="true"
fi

echo "${RESPONSE}" | jq '{id, name}' 2>/dev/null || true

# --- 5. Transfer to project (only on fresh creation, best effort) -----------
if [[ "${FRESHLY_CREATED}" == "true" && -n "${N8N_PROJECT_ID}" ]]; then
  echo "→ Transferring workflow ${NEW_ID} to project ${N8N_PROJECT_ID}..."
  TRANSFER_BODY="$(jq -n --arg p "${N8N_PROJECT_ID}" '{destinationProjectId: $p}')"
  RESULT="$(n8n_api PUT "/api/v1/workflows/${NEW_ID}/transfer" "${TRANSFER_BODY}")"
  STATUS="$(echo "${RESULT}" | head -n1)"
  if [[ "${STATUS}" == "200" || "${STATUS}" == "204" ]]; then
    echo "  ✓ transferred."
  else
    echo "  ! transfer returned HTTP ${STATUS} (ignorable on n8n Community edition)."
  fi
fi

echo ""
echo "✓ Deployed. Open the workflow:"
echo "  ${N8N_BASE_URL}/workflow/${NEW_ID}"
echo ""
echo "Next steps:"
echo "  • Run it once manually (Execute Workflow button) on a test short."
echo "  • When green, toggle it Active (top-right) so the weekly cron fires."
