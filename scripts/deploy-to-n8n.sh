#!/usr/bin/env bash
# Deploy (or update) the EO Shorts Auto-Publisher workflow to an n8n instance.
#
# Required env vars:
#   N8N_API_KEY   — JWT created in n8n UI: Settings → n8n API → Create API Key
#   N8N_BASE_URL  — optional, defaults to http://72.62.187.71:5678
#
# Usage:
#   export N8N_API_KEY="eyJhbGciOi..."
#   bash scripts/deploy-to-n8n.sh
#
# Behavior:
#   - If a workflow with the same name already exists on the instance, this
#     script PUTs the new definition over it (preserving its ID).
#   - Otherwise it POSTs a brand-new workflow and prints the assigned ID.
#   - The script never activates the workflow automatically — flip the toggle
#     in the n8n UI once you've validated a manual execution.

set -euo pipefail

N8N_BASE_URL="${N8N_BASE_URL:-http://72.62.187.71:5678}"
WORKFLOW_FILE="$(cd "$(dirname "$0")/.." && pwd)/workflows/eo-shorts-auto-publisher.json"
WORKFLOW_NAME="EO Shorts Auto-Publisher"

if [[ -z "${N8N_API_KEY:-}" ]]; then
  echo "error: N8N_API_KEY is not set." >&2
  echo "hint:  create one at ${N8N_BASE_URL}/settings/api" >&2
  exit 1
fi

if [[ ! -f "${WORKFLOW_FILE}" ]]; then
  echo "error: workflow file not found: ${WORKFLOW_FILE}" >&2
  exit 1
fi

# n8n's POST /workflows endpoint rejects extra top-level keys like `active`,
# `pinData`, or `staticData`. Strip them to the whitelist: name/nodes/connections/settings.
PAYLOAD="$(jq '{name, nodes, connections, settings}' "${WORKFLOW_FILE}")"

echo "→ Checking whether '${WORKFLOW_NAME}' already exists on ${N8N_BASE_URL}..."
EXISTING_ID="$(
  curl -fsSL \
    -H "X-N8N-API-KEY: ${N8N_API_KEY}" \
    -H "Accept: application/json" \
    "${N8N_BASE_URL}/api/v1/workflows" \
    | jq -r --arg n "${WORKFLOW_NAME}" '.data[] | select(.name == $n) | .id' \
    | head -n1
)"

if [[ -n "${EXISTING_ID}" ]]; then
  echo "→ Found existing workflow id=${EXISTING_ID}. Updating (PUT)..."
  RESPONSE="$(
    curl -fsSL \
      -X PUT \
      -H "X-N8N-API-KEY: ${N8N_API_KEY}" \
      -H "Content-Type: application/json" \
      --data "${PAYLOAD}" \
      "${N8N_BASE_URL}/api/v1/workflows/${EXISTING_ID}"
  )"
  echo "${RESPONSE}" | jq '{id, name, updatedAt}'
else
  echo "→ No existing workflow. Creating (POST)..."
  RESPONSE="$(
    curl -fsSL \
      -X POST \
      -H "X-N8N-API-KEY: ${N8N_API_KEY}" \
      -H "Content-Type: application/json" \
      --data "${PAYLOAD}" \
      "${N8N_BASE_URL}/api/v1/workflows"
  )"
  NEW_ID="$(echo "${RESPONSE}" | jq -r '.id')"
  echo "${RESPONSE}" | jq '{id, name, createdAt}'
  echo ""
  echo "✓ Workflow created. Open it:"
  echo "  ${N8N_BASE_URL}/workflow/${NEW_ID}"
fi

echo ""
echo "Next steps (manual, one time):"
echo "  1. In the n8n UI, configure these credentials if not already done:"
echo "     - 'Notion API' (notionApi) — Internal Integration Token"
echo "     - 'PostFast API' (httpHeaderAuth) — Header name 'Authorization',"
echo "       value 'Bearer KWn4JvZyT6HwerFf+SPdFX56OiIhuykHJmGGfWsnmpg='"
echo "  2. Set the POSTFAST_API_URL env var in n8n (Settings → Variables)"
echo "     to your PostFast scheduling endpoint."
echo "  3. Re-assign the credentials on the three affected nodes (n8n can't"
echo "     map credential IDs across instances automatically)."
echo "  4. Run once manually to validate, then toggle the workflow Active."
