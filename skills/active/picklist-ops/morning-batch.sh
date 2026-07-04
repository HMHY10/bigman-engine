#!/usr/bin/env bash
set -euo pipefail
# picklist-ops/morning-batch.sh — Auto-batch all overnight orders before warehouse opens
#
# Run as: doppler run -p shared-services -c prd -- ./morning-batch.sh
#
# Fetches ALL orders currently in "ready to pick" status (not yet batched),
# groups them by SKU, and generates one or more picklists. No hard order cap —
# same-SKU groups are never split across batches. When overnight volume is high
# for a single SKU, all matching orders go into the same picklist.
#
# If total orders exceed MORNING_MAX_PICKLIST_SIZE (default 200), splits into
# multiple sequential picklists to keep each physically manageable.

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

# Overnight fetch window: orders placed since midnight (or configurable hours back)
OVERNIGHT_HOURS_BACK="${OVERNIGHT_HOURS_BACK:-24}"
# Max orders per single picklist before splitting (0 = no split)
MORNING_MAX_PICKLIST_SIZE="${MORNING_MAX_PICKLIST_SIZE:-200}"

log "=== picklist-ops/morning-batch: starting ==="

picklist_state_init

# ── 1. Fetch ready orders ─────────────────────────────────────────────────
log "Fetching orders ready to pick (last ${OVERNIGHT_HOURS_BACK}h)..."
SINCE_TS=$(( $(date +%s) - OVERNIGHT_HOURS_BACK * 3600 ))
ALL_READY=$(picklist_fetch_ready_orders "$SINCE_TS")
READY_COUNT=$(printf '%s' "$ALL_READY" | jq 'length')
log "Ready orders: ${READY_COUNT}"

if (( READY_COUNT == 0 )); then
  log "No ready orders — nothing to batch"
  exit 0
fi

# ── 2. Filter out already-batched orders ──────────────────────────────────
PENDING=$(picklist_filter_unbatched "$ALL_READY")
PENDING_COUNT=$(printf '%s' "$PENDING" | jq 'length')
log "Unbatched orders: ${PENDING_COUNT}"

if (( PENDING_COUNT == 0 )); then
  log "All ready orders already batched — done"
  exit 0
fi

# ── 3. Fetch product locations (with cache) ───────────────────────────────
log "Fetching product locations..."
LOCATION_MAP=$(picklist_fetch_locations)

# ── 4. Sort pending orders by date (oldest first) ─────────────────────────
PENDING_SORTED=$(printf '%s' "$PENDING" | jq 'sort_by(.date_add // 0)')

# ── 5. Split into picklist chunks (respecting SKU group boundaries) ────────
# Strategy: chunk by MORNING_MAX_PICKLIST_SIZE, but never split a SKU group
# mid-way — extend or trim the chunk to align with SKU group boundaries.

TOTAL_BATCHED=0
BATCH_NUM=0
REMAINING="$PENDING_SORTED"

while true; do
  REMAINING_COUNT=$(printf '%s' "$REMAINING" | jq 'length')
  (( REMAINING_COUNT == 0 )) && break

  # Determine slice for this picklist
  if (( MORNING_MAX_PICKLIST_SIZE > 0 && REMAINING_COUNT > MORNING_MAX_PICKLIST_SIZE )); then
    # Take up to MORNING_MAX_PICKLIST_SIZE, then extend to include all orders
    # sharing a SKU with any order already in the slice (no-cap logic).
    SLICE=$(picklist_select_batch "$REMAINING" "$MORNING_MAX_PICKLIST_SIZE" 1)
  else
    # All remaining fit in one picklist
    SLICE="$REMAINING"
  fi

  SLICE_COUNT=$(printf '%s' "$SLICE" | jq 'length')
  (( SLICE_COUNT == 0 )) && break

  # Generate batch ID
  BATCH_ID=$(picklist_batch_id_gen)
  BATCH_NUM=$(( BATCH_NUM + 1 ))
  log "--- Generating picklist ${BATCH_ID} (${SLICE_COUNT} orders) ---"

  # Build SKU groups for this slice
  SKU_GROUPS=$(picklist_build_sku_groups "$SLICE" "$LOCATION_MAP")
  SKU_COUNT=$(printf '%s' "$SKU_GROUPS" | jq 'length')
  log "SKU groups: ${SKU_COUNT}"

  # Extract order IDs in this batch
  ORDER_IDS=$(printf '%s' "$SLICE" | jq -r '.[].order_id')

  # Build and save batch metadata
  BATCH_JSON=$(picklist_build_batch_json "$BATCH_ID" "overnight" "$ORDER_IDS")
  picklist_batch_save "$BATCH_ID" "$BATCH_JSON"

  # Mark orders as batched
  while IFS= read -r oid; do
    [[ -n "$oid" ]] && picklist_mark_batched "$oid"
  done <<< "$ORDER_IDS"

  # Generate HTML picklist
  HTML_FILE=$(picklist_generate_html "$BATCH_ID" "overnight" "$SLICE" "$SKU_GROUPS")
  log "Picklist HTML: ${HTML_FILE}"

  # Dispatch: vault archive + physical print
  picklist_dispatch "$BATCH_ID" "$HTML_FILE"

  TOTAL_BATCHED=$(( TOTAL_BATCHED + SLICE_COUNT ))

  # Remove this slice from remaining
  SLICE_IDS=$(printf '%s' "$SLICE" | jq '[.[].order_id | tostring]')
  REMAINING=$(printf '%s' "$REMAINING" | jq \
    --argjson ids "$SLICE_IDS" \
    '[.[] | select((.order_id | tostring) as $oid | ($ids | index($oid)) == null)]')
done

log "=== picklist-ops/morning-batch: complete ==="
log "  Batches generated: ${BATCH_NUM}"
log "  Orders batched: ${TOTAL_BATCHED}"
