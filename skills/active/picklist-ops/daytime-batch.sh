#!/usr/bin/env bash
set -euo pipefail
# picklist-ops/daytime-batch.sh — Rolling daytime batch generator
#
# Runs every 5 minutes during warehouse hours (cron handles timing).
# Fires a picklist when EITHER:
#   (a) >= PICKLIST_BATCH_SIZE new orders are waiting, OR
#   (b) PICKLIST_BATCH_MAX_WAIT minutes have elapsed since first new order arrived
#
# State: ${PICKLIST_STATE_DIR}/daytime-timer.json
#   {"started_at": "<iso8601>", "order_ids": [...]}
#
# Run as: doppler run -p shared-services -c prd -- ./daytime-batch.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/picklist-lib.sh"

TIMER_FILE="${PICKLIST_STATE_DIR}/daytime-timer.json"

log "=== picklist-ops/daytime-batch: starting ==="

# ── Fetch all currently-pending orders ───────────────────────────────
# "Pending" = BaseLinker status BL_STATUS_NEW (or all confirmed orders if not set).
# Use a 7-day lookback window so we catch any orders that slipped through
# earlier cycles.
LOOKBACK=$(( $(date +%s) - 604800 ))   # 7 days
ORDERS=$(pl_fetch_pending "$LOOKBACK")
TOTAL=$(printf '%s' "$ORDERS" | jq 'length')

log "daytime-batch: ${TOTAL} pending order(s) found"

# ── Nothing to do ─────────────────────────────────────────────────────
if (( TOTAL == 0 )); then
  # Reset the timer — no orders means no batch in progress
  if [[ -f "$TIMER_FILE" ]]; then
    rm -f "$TIMER_FILE"
    log "daytime-batch: timer reset (no pending orders)"
  fi
  log "=== daytime-batch: nothing to do ==="
  exit 0
fi

# ── Check timer ───────────────────────────────────────────────────────
NOW_TS=$(date +%s)
TIMER_ELAPSED=0
FIRE_REASON=""

if [[ -f "$TIMER_FILE" ]]; then
  STARTED_AT=$(jq -r '.started_at // empty' "$TIMER_FILE" 2>/dev/null || echo "")
  if [[ -n "$STARTED_AT" ]]; then
    STARTED_TS=$(date -d "$STARTED_AT" '+%s' 2>/dev/null \
              || date -j -f '%Y-%m-%dT%H:%M:%SZ' "$STARTED_AT" '+%s' 2>/dev/null \
              || echo "$NOW_TS")
    TIMER_ELAPSED=$(( (NOW_TS - STARTED_TS) / 60 ))
    log "daytime-batch: timer running for ${TIMER_ELAPSED} min (limit: ${PICKLIST_BATCH_MAX_WAIT} min)"
  fi
else
  # First time we see orders — start the timer
  jq -n \
    --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --argjson ids "$(printf '%s' "$ORDERS" | jq '[.[].order_id]')" \
    '{started_at: $ts, order_ids: $ids}' \
    > "$TIMER_FILE"
  log "daytime-batch: timer started (${TOTAL} orders waiting)"
fi

# ── Decide whether to fire ─────────────────────────────────────────────
if (( TOTAL >= PICKLIST_BATCH_SIZE )); then
  FIRE_REASON="threshold (${TOTAL} >= ${PICKLIST_BATCH_SIZE})"
elif (( TIMER_ELAPSED >= PICKLIST_BATCH_MAX_WAIT )); then
  FIRE_REASON="time-limit (${TIMER_ELAPSED} >= ${PICKLIST_BATCH_MAX_WAIT} min)"
fi

if [[ -z "$FIRE_REASON" ]]; then
  log "daytime-batch: holding — ${TOTAL} orders, ${TIMER_ELAPSED} min elapsed"
  log "=== daytime-batch: waiting ==="
  exit 0
fi

log "daytime-batch: firing — reason: ${FIRE_REASON}"

# ── Generate in batches of PICKLIST_BATCH_SIZE ────────────────────────
# If daytime load exceeds the batch size (e.g. >50 orders queued),
# generate multiple picklists of up to PICKLIST_BATCH_SIZE each.
OFFSET=0
PICKLIST_COUNT=0
PROCESSED=0

while (( OFFSET < TOTAL )); do
  BATCH=$(printf '%s' "$ORDERS" | jq \
    --argjson offset "$OFFSET" \
    --argjson size   "$PICKLIST_BATCH_SIZE" \
    '.[$offset : $offset + $size]')

  BATCH_SIZE=$(printf '%s' "$BATCH" | jq 'length')
  (( BATCH_SIZE == 0 )) && break

  log "daytime-batch: generating picklist for batch ${PICKLIST_COUNT} (${BATCH_SIZE} orders)"
  PL_ID=$(pl_create_picklist "$BATCH")
  log "daytime-batch: created ${PL_ID}"

  PICKLIST_COUNT=$(( PICKLIST_COUNT + 1 ))
  PROCESSED=$(( PROCESSED + BATCH_SIZE ))
  OFFSET=$(( OFFSET + PICKLIST_BATCH_SIZE ))
done

# ── Reset timer ───────────────────────────────────────────────────────
rm -f "$TIMER_FILE"
log "daytime-batch: timer reset"

log "=== daytime-batch: done — ${PICKLIST_COUNT} picklist(s), ${PROCESSED} orders ==="
