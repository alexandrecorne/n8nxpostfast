#!/usr/bin/env bash
# Deploy (or update) the EO Shorts Auto-Publisher workflow to an n8n instance.
#
# Required env vars:
#   N8N_API_KEY     — JWT created in n8n UI: Settings → n8n API → Create API Key
#
# Optional env vars:
#   N8N_BASE_URL    — defaults to http://72.62.187.71:5678
#   N8N_PROJECT_ID  — target project. If the workflow with the configured name
#                     already exists in that project, it is updated (PUT). If
#                     not, a new workflow is created and then moved into the
#                     project via the /projects/:id/workflows endpoint
#                     (only works on n8n editions that expose Projects).
#   TARGET_WORKFLOW_ID — overrides id auto-discovery (useful when the empty
#                     workflow already exists in the UI and you want to
#                     overwrite THAT specific one).
#
# Usage:
#   export N8N_API_KEY="eyJhbGciOi..."
#   export N8N_PROJECT_ID="bnK2w5BUU8YLwyol"
#   export TARGET_WORKFLOW_ID="VztWOvTejsjBV4Vh8tL2o"   # optional
#   bash scripts/deploy-to-n8n.sh
#
# Behavior:
#   - If TARGET_WORKFLOW_ID is set, PUTs directly to that id (preserves the
#     UI URL the user already has open).
#   - Otherwise if a workflow with the same name exists, PUTs over it.
#   - Otherwise POSTs a new workflow.
#   - The script never activates the workflow automatically — flip the toggle
#     in the n8n UI once you've validated a manual execution.

set -euo pipefail

N8N_BASE_URL="${N8N_BASE_URL:-http://72.62.187.71:5678}"
N8N_PROJECT_ID="${N8N_PROJECT_ID:-}"
TARGET_WORKFLOW_ID="${TARGET_WORKFLOW_ID:-}"
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

EXISTING_ID="${TARGET_WORKFLOW_ID}"
if [[ -z "${EXISTING_ID}" ]]; then
  echo "→ Checking whether '${WORKFLOW_NAME}' already exists on ${N8N_BASE_URL}..."
  EXISTING_ID="$(
    curl -fsSL \
      -H "X-N8N-API-KEY: ${N8N_API_KEY}" \
      -H "Accept: application/json" \
      "${N8N_BASE_URL}/api/v1/workflows" \
      | jq -r --arg n "${WORKFLOW_NAME}" '.data[] | select(.name == $n) | .id' \
      | head -n1
  )"
fi

if [[ -n "${EXISTING_ID}" ]]; then
  echo "→ Updating workflow id=${EXISTING_ID} (PUT)..."
  RESPONSE="$(
    curl -fsSL \
      -X PUT \
      -H "X-N8N-API-KEY: ${N8N_API_KEY}" \
      -H "Content-Type: application/json" \
      --data "${PAYLOAD}" \
      "${N8N_BASE_URL}/api/v1/workflows/${EXISTING_ID}"
  )"
  echo "${RESPONSE}" | jq '{id, name, updatedAt}'
  NEW_ID="${EXISTING_ID}"
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
fi

# If a project was specified AND we created a fresh workflow, move it into the
# project. n8n Cloud / Enterprise exposes this endpoint; Community edition
# ignores projects entirely so a 404 here is non-fatal.
if [[ -n "${N8N_PROJECT_ID}" && -z "${TARGET_WORKFLOW_ID}" ]]; then
  echo "→ Transferring workflow ${NEW_ID} to project ${N8N_PROJECT_ID}..."
  HTTP_CODE="$(
    curl -sS -o /tmp/n8n_transfer.out -w '%{http_code}' \
      -X PUT \
      -H "X-N8N-API-KEY: ${N8N_API_KEY}" \
      -H "Content-Type: application/json" \
      --data "{\"destinationProjectId\": \"${N8N_PROJECT_ID}\"}" \
      "${N8N_BASE_URL}/api/v1/workflows/${NEW_ID}/transfer" || echo 000
  )"
  if [[ "${HTTP_CODE}" == "200" || "${HTTP_CODE}" == "204" ]]; then
    echo "  ✓ transferred."
  else
    echo "  ! transfer returned HTTP ${HTTP_CODE} (ignorable on Community edition):"
    cat /tmp/n8n_transfer.out 2>/dev/null || true
    echo ""
  fi
fi

echo ""
echo "✓ Workflow ready. Open it:"
echo "  ${N8N_BASE_URL}/workflow/${NEW_ID}"

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
