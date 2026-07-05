#!/usr/bin/env bash
set -euo pipefail

# picklist-ops/run.sh — Auto-check: 25-order trigger + 1-hour time-limit fallback
#
# Runs every 5 minutes via cron.
# Fetches "ready to pick" orders from BaseLinker and decides whether to generate
# a picklist based on order count (≥25) or elapsed time since first ready order (≥1hr).
#
# Runs as: doppler run -p shared-services -c prd -- bash ./skills/active/picklist-ops/run.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../marketplace-lib" && pwd)"

source "${LIB_DIR}/config.sh"
source "${LIB_DIR}/cache.sh"
source "${LIB_DIR}/baselinker.sh"
source "${LIB_DIR}/alerts.sh"
source "${SCRIPT_DIR}/generate-picklist.sh"

# ── Configuration ─────────────────────────────────────────────────────
# All vars injected by Doppler
PICKLIST_READY_STATUS_ID="${PICKLIST_READY_STATUS_ID:?PICKLIST_READY_STATUS_ID not set}"
PICKLIST_PICKING_STATUS_ID="${PICKLIST_PICKING_STATUS_ID:-}"
PICKLIST_BATCH_SIZE="${PICKLIST_BATCH_SIZE:-25}"
PICKLIST_TIME_LIMIT="${PICKLIST_TIME_LIMIT:-3600}"  # 1 hour
PICKLIST_WEBHOOK_URL="${THEPOPEBOT_BASE_URL:?THEPOPEBOT_BASE_URL not set}"

STATE_DIR="${STATE_BASE}/picklist-ops"
mkdir -p "$STATE_DIR"

BATCH_START_FILE="${STATE_DIR}/batch-start-time"

log "=== picklist-ops/run: auto-check start ==="

# ── Fetch orders with READY status ────────────────────────────────────
# Fetch orders from BaseLinker with the "ready to pick" status.
# We look back 24h to avoid missing orders that arrived overnight.
SINCE_TS=$(( $(date +%s) - 86400 ))
log "Fetching orders with ready status (${PICKLIST_READY_STATUS_ID})..."
READY_ORDERS=$(bl_get_orders_by_status "$PICKLIST_READY_STATUS_ID" "$SINCE_TS" \
  || printf '%s' '[]')

READY_COUNT=$(printf '%s' "$READY_ORDERS" | jq 'length')
log "Ready orders found: ${READY_COUNT}"

# ── Handle empty queue ────────────────────────────────────────────────
if (( READY_COUNT == 0 )); then
  # Reset batch timer — no pending orders
  if [[ -f "$BATCH_START_FILE" ]]; then
    log "Queue empty — clearing batch timer"
    rm -f "$BATCH_START_FILE"
  fi
  log "=== picklist-ops/run: nothing to do ==="
  exit 0
fi

# ── Record batch start time ───────────────────────────────────────────
NOW=$(date +%s)

if [[ ! -f "$BATCH_START_FILE" ]]; then
  printf '%d' "$NOW" > "$BATCH_START_FILE"
  log "Batch timer started (first ready order detected)"
fi

BATCH_START=$(cat "$BATCH_START_FILE" 2>/dev/null || echo "$NOW")
ELAPSED=$(( NOW - BATCH_START ))
ELAPSED_MINS=$(( ELAPSED / 60 ))

log "Batch timer: ${ELAPSED_MINS} minutes elapsed (limit: $(( PICKLIST_TIME_LIMIT / 60 )) min)"

# ── Decide whether to trigger ─────────────────────────────────────────
SHOULD_TRIGGER=false
TRIGGER_REASON=""

if (( READY_COUNT >= PICKLIST_BATCH_SIZE )); then
  SHOULD_TRIGGER=true
  TRIGGER_REASON="batch-size (${READY_COUNT} orders ≥ ${PICKLIST_BATCH_SIZE})"
elif (( ELAPSED >= PICKLIST_TIME_LIMIT )) && (( READY_COUNT > 0 )); then
  SHOULD_TRIGGER=true
  TRIGGER_REASON="time-limit (${ELAPSED_MINS} min elapsed, ${READY_COUNT} orders available)"
else
  log "Not triggering: ${READY_COUNT}/${PICKLIST_BATCH_SIZE} orders, ${ELAPSED_MINS} min elapsed"
  log "=== picklist-ops/run: waiting ==="
  exit 0
fi

log "Triggering picklist: ${TRIGGER_REASON}"

# ── Take next batch (up to BATCH_SIZE, sorted by order_id) ───────────
BATCH=$(printf '%s' "$READY_ORDERS" | jq --argjson n "$PICKLIST_BATCH_SIZE" \
  'sort_by(.order_id) | .[:$n]')
BATCH_COUNT=$(printf '%s' "$BATCH" | jq 'length')

log "Generating picklist for ${BATCH_COUNT} orders..."

PICKLIST_ID=$(generate_picklist "$BATCH" "auto") || {
  log "ERROR: generate_picklist failed"
  exit 1
}

log "Picklist #${PICKLIST_ID} generated (${BATCH_COUNT} orders)"

# ── Reset batch timer ─────────────────────────────────────────────────
rm -f "$BATCH_START_FILE"

# If there are more ready orders remaining, restart the timer immediately
REMAINING=$(printf '%s' "$READY_ORDERS" | jq --argjson n "$PICKLIST_BATCH_SIZE" 'length - $n')
if (( REMAINING > 0 )); then
  printf '%d' "$(date +%s)" > "$BATCH_START_FILE"
  log "${REMAINING} orders remain in queue — batch timer restarted"
fi

log "=== picklist-ops/run: complete (picklist #${PICKLIST_ID}) ==="
