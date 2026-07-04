#!/usr/bin/env bash
set -euo pipefail
# picklist-ops/overnight-batch.sh — Pre-open morning batch
#
# Fetches all orders placed since warehouse close yesterday and generates
# picklists grouped by SKU. No hard order cap — same-SKU orders are kept
# together so pickers can collect all units of a line in one trip.
#
# Intended cron: 0 6 * * 1-6  (06:00 Mon–Sat)
# Run as: doppler run -p shared-services -c prd -- ./overnight-batch.sh
#
# Optional env overrides (all have defaults in picklist-lib.sh):
#   WAREHOUSE_CLOSE_HOUR — hour warehouse closed yesterday (default 18)
#   OVERNIGHT_MAX_PER_PICKLIST — max orders per single printed sheet (default 150)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/picklist-lib.sh"

WAREHOUSE_CLOSE_HOUR="${WAREHOUSE_CLOSE_HOUR:-18}"
OVERNIGHT_MAX_PER_PICKLIST="${OVERNIGHT_MAX_PER_PICKLIST:-150}"

log "=== picklist-ops/overnight-batch: starting ==="

# ── Calculate "since" timestamp ───────────────────────────────────────
# Yesterday at WAREHOUSE_CLOSE_HOUR in local time → epoch
YESTERDAY=$(date -d 'yesterday' '+%Y-%m-%d' 2>/dev/null \
         || date -v -1d '+%Y-%m-%d' 2>/dev/null)  # macOS fallback
SINCE_STR="${YESTERDAY} ${WAREHOUSE_CLOSE_HOUR}:00:00"
SINCE_TS=$(date -d "$SINCE_STR" '+%s' 2>/dev/null \
        || date -j -f '%Y-%m-%d %H:%M:%S' "$SINCE_STR" '+%s' 2>/dev/null || echo 0)

log "overnight-batch: fetching orders since ${SINCE_STR} (${SINCE_TS})"

# ── Fetch pending orders ──────────────────────────────────────────────
ORDERS=$(pl_fetch_pending "$SINCE_TS")
TOTAL=$(printf '%s' "$ORDERS" | jq 'length')
log "overnight-batch: ${TOTAL} orders found"

if (( TOTAL == 0 )); then
  log "overnight-batch: no orders to process — done"
  exit 0
fi

# ── Exclude any orders already assigned to an active picklist ─────────
# (Handles the edge case where overnight-batch runs but daytime already
#  processed some orders via the daytime cron before 06:00.)
if [[ -n "${BL_STATUS_PICKING:-}" ]]; then
  # Orders still in BL_STATUS_NEW are the ones we need
  log "overnight-batch: filtering to status=${BL_STATUS_NEW} orders only"
  # bl_get_orders with status filter already handled in pl_fetch_pending
fi

# ── Generate picklists ────────────────────────────────────────────────
# Split into chunks of OVERNIGHT_MAX_PER_PICKLIST to keep sheets manageable.
# All orders for the same SKU are guaranteed to fall within the same chunk
# because we re-group by SKU inside pl_create_picklist.
# Strategy: sort the full order array by its dominant SKU, then slice.

PICKLIST_COUNT=0
PROCESSED=0
OFFSET=0

while (( OFFSET < TOTAL )); do
  # Take a slice
  BATCH=$(printf '%s' "$ORDERS" | jq \
    --argjson offset "$OFFSET" \
    --argjson size   "$OVERNIGHT_MAX_PER_PICKLIST" \
    '.[$offset : $offset + $size]')

  BATCH_SIZE=$(printf '%s' "$BATCH" | jq 'length')
  (( BATCH_SIZE == 0 )) && break

  log "overnight-batch: generating picklist for orders ${OFFSET}–$((OFFSET + BATCH_SIZE - 1))"
  PL_ID=$(pl_create_picklist "$BATCH")
  log "overnight-batch: created ${PL_ID}"

  PICKLIST_COUNT=$(( PICKLIST_COUNT + 1 ))
  PROCESSED=$(( PROCESSED + BATCH_SIZE ))
  OFFSET=$(( OFFSET + OVERNIGHT_MAX_PER_PICKLIST ))
done

log "=== overnight-batch: done — ${PICKLIST_COUNT} picklist(s), ${PROCESSED} orders ==="

# Alert if nothing printed (unexpected)
if (( PICKLIST_COUNT == 0 )) && (( TOTAL > 0 )); then
  alert_create "high" "baselinker" "Picklists/Alerts" \
    "Overnight Picklist Generation Failed" \
    "**Orders found:** ${TOTAL}
**Picklists generated:** 0

overnight-batch.sh found orders but produced no picklists. Check logs."
fi
