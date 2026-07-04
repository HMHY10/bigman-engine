#!/usr/bin/env bash
set -euo pipefail
# picklist-ops/manual-batch.sh — Print next 25 or print selected orders
#
# Called via webhook trigger. Two modes:
#
#   Mode 1 — "Print next 25" (no arguments):
#     Takes the next PICKLIST_BATCH_SIZE pending orders and generates a picklist.
#     bash manual-batch.sh
#
#   Mode 2 — "Print selected orders" (comma-separated order IDs):
#     Generates a picklist for the specified order IDs regardless of their
#     batched status (allows re-printing or forcing specific orders).
#     bash manual-batch.sh "125001,125002,125003"
#
# Triggered via TRIGGERS.json webhook:
#   POST /webhook {"action": "manual-batch"}
#   POST /webhook {"action": "manual-batch", "order_ids": "125001,125002"}

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

ORDER_IDS_ARG="${1:-}"  # Optional: comma-separated order IDs

log "=== picklist-ops/manual-batch: starting ==="
[[ -n "$ORDER_IDS_ARG" ]] && log "Mode: selected orders (${ORDER_IDS_ARG})" || log "Mode: print next ${PICKLIST_BATCH_SIZE}"

picklist_state_init

# ── Fetch product locations ───────────────────────────────────────────────
log "Fetching product locations..."
LOCATION_MAP=$(picklist_fetch_locations)

# ── Mode 1: selected order IDs ────────────────────────────────────────────
if [[ -n "$ORDER_IDS_ARG" ]]; then
  # Split comma-separated IDs and fetch each order from BaseLinker
  BATCH_ORDERS="[]"
  FAILED_IDS=""

  IFS=',' read -ra IDS <<< "$ORDER_IDS_ARG"
  for raw_id in "${IDS[@]}"; do
    oid=$(printf '%s' "$raw_id" | tr -cd '[:digit:]')
    [[ -z "$oid" ]] && continue

    log "Fetching order ${oid}..."
    params=$(jq -n --argjson id "$oid" '{order_id: $id}')
    result=$(bl_request "getOrders" "$params" 2>/dev/null || echo '{"orders":[]}')
    order=$(printf '%s' "$result" | jq -c '.orders[0]? // empty')

    if [[ -n "$order" ]]; then
      BATCH_ORDERS=$(printf '%s' "$BATCH_ORDERS" | jq --argjson o "$order" '. + [$o]')
    else
      log "manual-batch: order ${oid} not found in BaseLinker"
      FAILED_IDS="${FAILED_IDS} ${oid}"
    fi
  done

  BATCH_COUNT=$(printf '%s' "$BATCH_ORDERS" | jq 'length')

  if (( BATCH_COUNT == 0 )); then
    log "No valid orders found — aborting"
    exit 1
  fi

  [[ -n "$FAILED_IDS" ]] && log "WARN: could not fetch orders:${FAILED_IDS}"

# ── Mode 2: next N pending orders ─────────────────────────────────────────
else
  SINCE_TS=$(( $(date +%s) - 172800 ))  # 48h window
  ALL_READY=$(picklist_fetch_ready_orders "$SINCE_TS")
  PENDING=$(picklist_filter_unbatched "$ALL_READY")
  PENDING_COUNT=$(printf '%s' "$PENDING" | jq 'length')

  log "Pending unbatched orders: ${PENDING_COUNT}"

  if (( PENDING_COUNT == 0 )); then
    log "No pending orders to print"
    exit 0
  fi

  # Select next batch with SKU extension (same-SKU never split)
  BATCH_ORDERS=$(picklist_select_batch "$PENDING" "$PICKLIST_BATCH_SIZE" 1)
  BATCH_COUNT=$(printf '%s' "$BATCH_ORDERS" | jq 'length')
fi

# ── Generate picklist ─────────────────────────────────────────────────────
BATCH_ID=$(picklist_batch_id_gen)
log "--- Generating manual picklist ${BATCH_ID} (${BATCH_COUNT} orders) ---"

SKU_GROUPS=$(picklist_build_sku_groups "$BATCH_ORDERS" "$LOCATION_MAP")
SKU_COUNT=$(printf '%s' "$SKU_GROUPS" | jq 'length')
log "SKU groups: ${SKU_COUNT}"

BATCH_ORDER_IDS=$(printf '%s' "$BATCH_ORDERS" | jq -r '.[].order_id')

# Save batch metadata
BATCH_JSON=$(picklist_build_batch_json "$BATCH_ID" "manual" "$BATCH_ORDER_IDS")
picklist_batch_save "$BATCH_ID" "$BATCH_JSON"

# Mark orders as batched (only for "next N" mode — selected orders may already be batched)
if [[ -z "$ORDER_IDS_ARG" ]]; then
  while IFS= read -r oid; do
    [[ -n "$oid" ]] && picklist_mark_batched "$oid"
  done <<< "$BATCH_ORDER_IDS"
fi

# Generate HTML and dispatch
HTML_FILE=$(picklist_generate_html "$BATCH_ID" "manual" "$BATCH_ORDERS" "$SKU_GROUPS")
log "Picklist HTML: ${HTML_FILE}"

picklist_dispatch "$BATCH_ID" "$HTML_FILE"

log "=== picklist-ops/manual-batch: complete ==="
log "  Batch ID: ${BATCH_ID}"
log "  Orders: ${BATCH_COUNT} | SKUs: ${SKU_COUNT}"
