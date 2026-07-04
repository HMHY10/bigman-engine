#!/usr/bin/env bash
set -euo pipefail
# picklist-ops/daytime-batch.sh — Daytime ~25-order batching with time-limit fallback
#
# Run as: doppler run -p shared-services -c prd -- ./daytime-batch.sh
# Scheduled every 30 minutes during warehouse hours (e.g. 08:00-17:00 Mon-Fri).
#
# Trigger logic:
#   - If >= PICKLIST_BATCH_SIZE orders are pending → batch immediately
#   - If < PICKLIST_BATCH_SIZE orders but PICKLIST_TIME_FALLBACK_MINS have
#     elapsed since the last batch → batch whatever is available
#   - Otherwise → exit quietly (wait for more orders or next cron tick)
#
# Batch extension: after selecting the initial ~25 orders, any additional
# pending orders that share a SKU with the selected set are added so the
# picker clears each bin in one trip. This can push the batch above 25.

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

log "=== picklist-ops/daytime-batch: starting ==="

picklist_state_init

# ── 1. Fetch ready orders ─────────────────────────────────────────────────
# Use a 48-hour window to catch any orders that arrived since last morning batch
SINCE_TS=$(( $(date +%s) - 172800 ))
ALL_READY=$(picklist_fetch_ready_orders "$SINCE_TS")

# ── 2. Filter unbatched ───────────────────────────────────────────────────
PENDING=$(picklist_filter_unbatched "$ALL_READY")
PENDING_COUNT=$(printf '%s' "$PENDING" | jq 'length')
log "Pending unbatched orders: ${PENDING_COUNT}"

# ── 3. Decide whether to batch now ───────────────────────────────────────
if (( PENDING_COUNT == 0 )); then
  log "No pending orders — nothing to batch"
  exit 0
fi

TRIGGER="none"

if (( PENDING_COUNT >= PICKLIST_BATCH_SIZE )); then
  TRIGGER="threshold"
  log "Threshold reached (${PENDING_COUNT} >= ${PICKLIST_BATCH_SIZE}) — batching now"
elif picklist_should_force_batch; then
  TRIGGER="time_fallback"
  log "Time fallback triggered — batching ${PENDING_COUNT} available orders"
fi

if [[ "$TRIGGER" == "none" ]]; then
  log "Pending orders (${PENDING_COUNT}) below threshold and within quiet window — waiting"
  exit 0
fi

# ── 4. Fetch product locations ────────────────────────────────────────────
log "Fetching product locations..."
LOCATION_MAP=$(picklist_fetch_locations)

# ── 5. Select batch (target size + SKU extension) ─────────────────────────
# picklist_select_batch handles extending beyond BATCH_SIZE for same-SKU orders
BATCH_ORDERS=$(picklist_select_batch "$PENDING" "$PICKLIST_BATCH_SIZE" 1)
BATCH_COUNT=$(printf '%s' "$BATCH_ORDERS" | jq 'length')

if (( BATCH_COUNT == 0 )); then
  log "No orders selected — exiting"
  exit 0
fi

if (( BATCH_COUNT > PICKLIST_BATCH_SIZE )); then
  EXTENDED=$(( BATCH_COUNT - PICKLIST_BATCH_SIZE ))
  log "Batch extended by ${EXTENDED} same-SKU order(s) beyond target of ${PICKLIST_BATCH_SIZE}"
fi

# ── 6. Generate picklist ──────────────────────────────────────────────────
BATCH_ID=$(picklist_batch_id_gen)
log "--- Generating daytime picklist ${BATCH_ID} (${BATCH_COUNT} orders) ---"

SKU_GROUPS=$(picklist_build_sku_groups "$BATCH_ORDERS" "$LOCATION_MAP")
SKU_COUNT=$(printf '%s' "$SKU_GROUPS" | jq 'length')
log "SKU groups: ${SKU_COUNT}"

ORDER_IDS=$(printf '%s' "$BATCH_ORDERS" | jq -r '.[].order_id')

# Save batch metadata
BATCH_JSON=$(picklist_build_batch_json "$BATCH_ID" "daytime" "$ORDER_IDS")
picklist_batch_save "$BATCH_ID" "$BATCH_JSON"

# Mark orders as batched
while IFS= read -r oid; do
  [[ -n "$oid" ]] && picklist_mark_batched "$oid"
done <<< "$ORDER_IDS"

# ── 7. Generate HTML and dispatch ────────────────────────────────────────
HTML_FILE=$(picklist_generate_html "$BATCH_ID" "daytime" "$BATCH_ORDERS" "$SKU_GROUPS")
log "Picklist HTML: ${HTML_FILE}"

picklist_dispatch "$BATCH_ID" "$HTML_FILE"

# ── 8. Update last-batch timestamp ───────────────────────────────────────
picklist_update_last_batch_time

log "=== picklist-ops/daytime-batch: complete ==="
log "  Batch ID: ${BATCH_ID}"
log "  Orders: ${BATCH_COUNT} | SKUs: ${SKU_COUNT} | Trigger: ${TRIGGER}"
