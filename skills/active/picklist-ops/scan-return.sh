#!/usr/bin/env bash
set -euo pipefail
# picklist-ops/scan-return.sh — Handle QR code scan on picklist return
#
# Called when a picker returns from the warehouse and scans the QR code
# printed on their picklist. The QR code encodes the batch ID (e.g. PL-20260704-001).
#
# Actions:
#   1. Load batch metadata and validate it exists + hasn't been processed
#   2. For each order in the batch: fetch existing courier packages, print labels
#   3. Update BaseLinker order statuses to PICKLIST_PACKED_STATUS_ID
#   4. Mark batch as "picked" in local state
#   5. Write vault completion note
#
# Usage:
#   bash scan-return.sh PL-20260704-001
#
# Triggered via TRIGGERS.json webhook:
#   POST /webhook {"action": "scan-return", "batch_id": "PL-20260704-001"}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/../marketplace-lib" && pwd)"
PICKLIST_LIB_DIR="${SCRIPT_DIR}/lib"

source "${LIB_DIR}/config.sh"
source "${LIB_DIR}/cache.sh"
source "${LIB_DIR}/baselinker.sh"
source "${LIB_DIR}/alerts.sh"
source "${PICKLIST_LIB_DIR}/core.sh"
source "${PICKLIST_LIB_DIR}/picklist.sh"
source "${PICKLIST_LIB_DIR}/print.sh"
source "${PICKLIST_LIB_DIR}/labels.sh"

BATCH_ID="${1:-}"

# ── Validate input ────────────────────────────────────────────────────────
if [[ -z "$BATCH_ID" ]]; then
  log "scan-return: ERROR — no batch_id provided"
  echo "Usage: $0 <batch_id>" >&2
  exit 1
fi

# Sanitise: batch IDs are alphanumeric + hyphens only
BATCH_ID=$(printf '%s' "$BATCH_ID" | tr -cd '[:alnum:]-')

if [[ -z "$BATCH_ID" ]]; then
  log "scan-return: ERROR — invalid batch_id after sanitisation"
  exit 1
fi

log "=== picklist-ops/scan-return: ${BATCH_ID} ==="

picklist_state_init

# ── Load and validate batch ───────────────────────────────────────────────
BATCH_JSON=$(picklist_batch_load "$BATCH_ID") || {
  log "scan-return: batch ${BATCH_ID} not found in state"
  # Alert if batch ID looks valid but doesn't exist (potential scan error)
  alert_create "high" "warehouse" "Warehouse/Alerts" \
    "Unknown Picklist Scanned: ${BATCH_ID}" \
    "**Batch ID:** ${BATCH_ID}
**Time:** $(date -u '+%Y-%m-%d %H:%M:%S UTC')

A QR code was scanned with batch ID \`${BATCH_ID}\` but no matching picklist was found in state. This may indicate a mis-scan, a duplicate scan of an old picklist, or a state issue.

Please check the physical picklist and verify the batch ID."
  exit 1
}

BATCH_STATUS=$(printf '%s' "$BATCH_JSON" | jq -r '.status // ""')
ORDER_COUNT=$(printf '%s' "$BATCH_JSON" | jq '.order_ids | length')

log "Batch status: ${BATCH_STATUS} | Orders: ${ORDER_COUNT}"

if [[ "$BATCH_STATUS" == "picked" ]]; then
  log "scan-return: ${BATCH_ID} already processed — ignoring duplicate scan"
  exit 0
fi

# ── Process: print labels + update statuses ───────────────────────────────
log "Processing scan return for ${BATCH_ID} (${ORDER_COUNT} orders)..."

labels_process_batch "$BATCH_ID"

log "=== picklist-ops/scan-return: complete ==="
log "  Batch: ${BATCH_ID} | Orders: ${ORDER_COUNT}"
log "  Label printer: ${LABEL_PRINTER_NAME:-not configured}"
