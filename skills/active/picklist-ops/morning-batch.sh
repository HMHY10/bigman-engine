#!/usr/bin/env bash
set -euo pipefail

# picklist-ops/morning-batch.sh — 7am morning batch
#
# Fetches ALL orders in the "ready to pick" status accumulated overnight
# and generates a single consolidated picklist grouped by SKU.
# No 25-order cap. Resets the daily batch state.
#
# Runs as: doppler run -p shared-services -c prd -- bash ./skills/active/picklist-ops/morning-batch.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../marketplace-lib" && pwd)"

source "${LIB_DIR}/config.sh"
source "${LIB_DIR}/cache.sh"
source "${LIB_DIR}/baselinker.sh"
source "${LIB_DIR}/alerts.sh"
source "${SCRIPT_DIR}/generate-picklist.sh"

# ── Configuration ─────────────────────────────────────────────────────
PICKLIST_READY_STATUS_ID="${PICKLIST_READY_STATUS_ID:?PICKLIST_READY_STATUS_ID not set}"
PICKLIST_PICKING_STATUS_ID="${PICKLIST_PICKING_STATUS_ID:-}"
PICKLIST_WEBHOOK_URL="${THEPOPEBOT_BASE_URL:?THEPOPEBOT_BASE_URL not set}"

STATE_DIR="${STATE_BASE}/picklist-ops"
mkdir -p "$STATE_DIR"

TODAY=$(date '+%Y-%m-%d')
MORNING_MARKER="${STATE_DIR}/morning-batch-${TODAY}"
BATCH_START_FILE="${STATE_DIR}/batch-start-time"

log "=== picklist-ops/morning-batch: starting ==="

# ── Idempotency guard ─────────────────────────────────────────────────
if [[ -f "$MORNING_MARKER" ]]; then
  log "Morning batch already run today (${TODAY}) — skipping"
  log "=== picklist-ops/morning-batch: already done ==="
  exit 0
fi

# ── Fetch ALL overnight ready orders ─────────────────────────────────
# Look back 18 hours to capture orders from yesterday evening through now.
SINCE_TS=$(( $(date +%s) - 64800 ))
log "Fetching all ready orders since $(date -d "@${SINCE_TS}" '+%H:%M %d/%m' 2>/dev/null || date -r "${SINCE_TS}" '+%H:%M %d/%m' 2>/dev/null || echo "${SINCE_TS}")..."

READY_ORDERS=$(bl_get_orders_by_status "$PICKLIST_READY_STATUS_ID" "$SINCE_TS" \
  || printf '%s' '[]')

READY_COUNT=$(printf '%s' "$READY_ORDERS" | jq 'length')
log "Ready orders for morning batch: ${READY_COUNT}"

# ── Handle empty queue ────────────────────────────────────────────────
if (( READY_COUNT == 0 )); then
  log "No orders in ready status — nothing to print"
  # Still mark as done so subsequent auto-check runs cleanly today
  touch "$MORNING_MARKER"
  rm -f "$BATCH_START_FILE"
  log "=== picklist-ops/morning-batch: nothing to do ==="
  exit 0
fi

# ── Generate consolidated picklist (all orders, no cap) ───────────────
log "Generating morning picklist for all ${READY_COUNT} orders..."

PICKLIST_ID=$(generate_picklist "$READY_ORDERS" "morning") || {
  log "ERROR: generate_picklist failed"
  exit 1
}

log "Morning picklist #${PICKLIST_ID} generated (${READY_COUNT} orders)"

# ── Reset batch state ─────────────────────────────────────────────────
touch "$MORNING_MARKER"
rm -f "$BATCH_START_FILE"

# Clean up morning markers older than 7 days to avoid state buildup
find "$STATE_DIR" -name 'morning-batch-*' -mtime +7 -delete 2>/dev/null || true

log "=== picklist-ops/morning-batch: complete (picklist #${PICKLIST_ID}, ${READY_COUNT} orders) ==="
