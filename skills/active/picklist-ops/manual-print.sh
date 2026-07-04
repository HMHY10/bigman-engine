#!/usr/bin/env bash
set -euo pipefail
# picklist-ops/manual-print.sh — On-demand picklist printing
#
# Usage:
#   ./manual-print.sh                      # Print next PICKLIST_BATCH_SIZE orders
#   ./manual-print.sh --count 10           # Print next 10 orders
#   ./manual-print.sh --orders 12345,12346 # Print specific order IDs
#
# Run as: doppler run -p shared-services -c prd -- ./manual-print.sh [options]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/picklist-lib.sh"

# ── Parse arguments ───────────────────────────────────────────────────
MODE="next"          # "next" | "specific"
COUNT="$PICKLIST_BATCH_SIZE"
ORDER_IDS_CSV=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --count)
      COUNT="${2:?--count requires a value}"
      shift 2
      ;;
    --orders)
      MODE="specific"
      ORDER_IDS_CSV="${2:?--orders requires a comma-separated list of order IDs}"
      shift 2
      ;;
    *)
      echo "Usage: $0 [--count N] [--orders ID1,ID2,...]" >&2
      exit 1
      ;;
  esac
done

log "=== picklist-ops/manual-print: mode=${MODE} ==="

# ── MODE: specific order IDs ──────────────────────────────────────────
if [[ "$MODE" == "specific" ]]; then
  log "manual-print: fetching specific orders: ${ORDER_IDS_CSV}"

  # Fetch each order individually and combine
  ORDERS="[]"
  IFS=',' read -ra IDS <<< "$ORDER_IDS_CSV"
  for OID in "${IDS[@]}"; do
    OID=$(printf '%s' "$OID" | tr -d ' ')
    [[ -z "$OID" ]] && continue

    ORDER_RAW=$(bl_request "getOrders" \
      "$(jq -n --argjson oid "$OID" '{order_id: $oid}')" 2>/dev/null \
      || printf '%s' '{"orders":[]}')
    [[ -z "$ORDER_RAW" ]] && ORDER_RAW='{"orders":[]}'

    BATCH=$(printf '%s' "$ORDER_RAW" | jq '.orders // []')
    ORDERS=$(printf '%s\n%s' "$ORDERS" "$BATCH" | jq -s 'add // []')
  done

  TOTAL=$(printf '%s' "$ORDERS" | jq 'length')
  log "manual-print: fetched ${TOTAL} of ${#IDS[@]} requested orders"

  if (( TOTAL == 0 )); then
    log "manual-print: no orders found for IDs: ${ORDER_IDS_CSV}"
    exit 1
  fi

  PL_ID=$(pl_create_picklist "$ORDERS")
  log "manual-print: created ${PL_ID} for specific orders"
  printf 'Picklist created: %s\n' "$PL_ID"
  exit 0
fi

# ── MODE: next N orders ───────────────────────────────────────────────
log "manual-print: fetching next ${COUNT} pending orders"

LOOKBACK=$(( $(date +%s) - 604800 ))   # 7-day window
ALL_ORDERS=$(pl_fetch_pending "$LOOKBACK")
TOTAL=$(printf '%s' "$ALL_ORDERS" | jq 'length')
log "manual-print: ${TOTAL} pending order(s) available"

if (( TOTAL == 0 )); then
  log "manual-print: no pending orders found"
  printf 'No pending orders to print.\n'
  exit 0
fi

# Take first COUNT orders
ORDERS=$(printf '%s' "$ALL_ORDERS" | jq --argjson n "$COUNT" '.[:$n]')
BATCH_SIZE=$(printf '%s' "$ORDERS" | jq 'length')
log "manual-print: printing ${BATCH_SIZE} orders"

PL_ID=$(pl_create_picklist "$ORDERS")
log "manual-print: created ${PL_ID}"
printf 'Picklist created: %s (%d orders)\n' "$PL_ID" "$BATCH_SIZE"
