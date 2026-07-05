#!/usr/bin/env bash
set -euo pipefail

# picklist-ops/print-selected.sh — Manual "Print selected orders" button handler
#
# Receives a JSON body with a list of specific order IDs and generates
# a picklist for just those orders.
#
# Usage:
#   print-selected.sh '{"order_ids": [12345, 12346, 12347]}'
#
# Called via TRIGGERS.json when POST /api/webhook/picklist-print-selected fires.
# Runs as: doppler run -p shared-services -c prd -- bash ./skills/active/picklist-ops/print-selected.sh <body>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../marketplace-lib" && pwd)"

source "${LIB_DIR}/config.sh"
source "${LIB_DIR}/cache.sh"
source "${LIB_DIR}/baselinker.sh"
source "${LIB_DIR}/alerts.sh"
source "${SCRIPT_DIR}/generate-picklist.sh"

# ── Configuration ─────────────────────────────────────────────────────
PICKLIST_PICKING_STATUS_ID="${PICKLIST_PICKING_STATUS_ID:-}"
PICKLIST_WEBHOOK_URL="${THEPOPEBOT_BASE_URL:?THEPOPEBOT_BASE_URL not set}"

STATE_DIR="${STATE_BASE}/picklist-ops"
mkdir -p "$STATE_DIR"

# ── Parse request body ────────────────────────────────────────────────
RAW_BODY="${1:-}"

if [[ -z "$RAW_BODY" ]]; then
  log "ERROR: No body provided. Expected: {\"order_ids\": [12345, 12346]}"
  exit 1
fi

if ! printf '%s' "$RAW_BODY" | jq -e . &>/dev/null; then
  log "ERROR: Invalid JSON body: ${RAW_BODY}"
  exit 1
fi

ORDER_IDS_INPUT=$(printf '%s' "$RAW_BODY" | jq -c '.order_ids // .orders // []')
ID_COUNT=$(printf '%s' "$ORDER_IDS_INPUT" | jq 'length')

if (( ID_COUNT == 0 )); then
  log "ERROR: No order_ids in body: ${RAW_BODY}"
  exit 1
fi

log "=== picklist-ops/print-selected: ${ID_COUNT} orders requested ==="

# ── Fetch full order details for each requested ID ────────────────────
ORDERS="[]"
FOUND=0
NOT_FOUND=0

while IFS= read -r order_id; do
  [[ -z "$order_id" ]] && continue
  log "Fetching order ${order_id}..."
  ORDER=$(bl_get_order_details "$order_id" 2>/dev/null || echo "")
  if [[ -n "$ORDER" && "$ORDER" != "null" ]]; then
    ORDERS=$(printf '%s' "$ORDERS" | jq --argjson o "$ORDER" '. + [$o]')
    FOUND=$((FOUND + 1))
  else
    log "WARNING: Order ${order_id} not found or inaccessible"
    NOT_FOUND=$((NOT_FOUND + 1))
  fi
done < <(printf '%s' "$ORDER_IDS_INPUT" | jq -r '.[]')

log "Orders fetched: ${FOUND} found, ${NOT_FOUND} not found"

if (( FOUND == 0 )); then
  log "ERROR: None of the requested orders could be fetched"
  exit 1
fi

# ── Generate picklist ─────────────────────────────────────────────────
PICKLIST_ID=$(generate_picklist "$ORDERS" "manual-selected") || {
  log "ERROR: generate_picklist failed"
  exit 1
}

log "=== picklist-ops/print-selected: complete (picklist #${PICKLIST_ID}, ${FOUND} orders) ==="
