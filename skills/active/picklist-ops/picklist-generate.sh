#!/usr/bin/env bash
set -euo pipefail

# picklist-ops/picklist-generate.sh — Generate a SKU-grouped picklist from BaseLinker ready orders
#
# Usage:
#   picklist-generate.sh batch [N]              — next N unprinted orders (default: PICKLIST_BATCH_SIZE)
#   picklist-generate.sh all                    — ALL ready orders (morning batch, no cap)
#   picklist-generate.sh ids <ID1> [ID2 ...]    — specific order IDs (manual selection)
#
# Runs as: doppler run -p shared-services -c prd -- ./picklist-generate.sh <mode> [args]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../marketplace-lib" && pwd)"

source "${LIB_DIR}/config.sh"
source "${LIB_DIR}/cache.sh"
source "${LIB_DIR}/baselinker.sh"
source "${LIB_DIR}/alerts.sh"
source "${SCRIPT_DIR}/picklist-lib.sh"

picklist_init
expire_printed_orders

MODE="${1:-batch}"
BATCH_ARG="${2:-}"

if [[ -z "${PICKLIST_READY_STATUS_ID:-}" ]]; then
  log "ERROR: PICKLIST_READY_STATUS_ID not set — configure in Doppler (shared-services)"
  exit 1
fi

log "=== picklist-generate: mode=${MODE} ==="

# ── Fetch all ready orders ─────────────────────────────────────────────
SINCE=$(since_epoch "$PICKLIST_SINCE_HOURS")
log "Fetching ready orders (status=${PICKLIST_READY_STATUS_ID}, since=$(date -u -d "@${SINCE}" '+%Y-%m-%d %H:%M' 2>/dev/null || date -u -r "${SINCE}" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "@${SINCE}"))..."

ALL_READY=$(bl_get_orders "$SINCE" "$PICKLIST_READY_STATUS_ID") || {
  log "ERROR: failed to fetch orders from BaseLinker"
  exit 1
}

TOTAL_READY=$(printf '%s' "$ALL_READY" | jq 'length')
log "Total ready orders found: ${TOTAL_READY}"

if (( TOTAL_READY == 0 )); then
  log "No ready orders — nothing to print"
  exit 0
fi

# ── Select orders based on mode ────────────────────────────────────────
case "$MODE" in

  all)
    # Morning batch — take all ready orders, oldest first, no cap
    ORDERS=$(printf '%s' "$ALL_READY" | jq 'sort_by(.date_add)')
    MODE_LABEL="morning-all"
    ;;

  ids)
    # Manual selection — shift past mode arg, rest are order IDs
    shift; [[ $# -gt 0 ]] && shift || true
    if [[ $# -eq 0 ]]; then
      log "ERROR: 'ids' mode requires at least one order ID argument"
      exit 1
    fi
    IDS_JSON=$(printf '%s\n' "$@" | jq -R 'tonumber' | jq -s '.')
    ORDERS=$(printf '%s' "$ALL_READY" | jq \
      --argjson ids "$IDS_JSON" \
      '[.[] | select(.order_id as $id | $ids | index($id) != null)]')
    FOUND=$(printf '%s' "$ORDERS" | jq 'length')
    REQUESTED=$(printf '%s' "$IDS_JSON" | jq 'length')
    if (( FOUND < REQUESTED )); then
      log "Warning: ${FOUND} of ${REQUESTED} requested orders found in ready status"
    fi
    MODE_LABEL="manual-selected"
    ;;

  batch|*)
    # Auto-batch — oldest N unprinted orders
    BATCH_LIMIT="${BATCH_ARG:-${PICKLIST_BATCH_SIZE}}"
    PRINTED=$(printed_orders_load)
    ORDERS=$(printf '%s' "$ALL_READY" | jq \
      --argjson printed "$PRINTED" \
      --argjson limit "$BATCH_LIMIT" \
      '[.[] | select(.order_id as $id | $printed | index($id) == null)] |
       sort_by(.date_add) |
       .[:($limit | tonumber)]')
    MODE_LABEL="auto-batch-${BATCH_LIMIT}"
    ;;
esac

ORDER_COUNT=$(printf '%s' "$ORDERS" | jq 'length')
if (( ORDER_COUNT == 0 )); then
  log "No orders to process for mode=${MODE} — exiting"
  exit 0
fi
log "Orders selected for picklist: ${ORDER_COUNT}"

# ── Build SKU groups ───────────────────────────────────────────────────
log "Building SKU groups..."
SKU_GROUPS=$(build_sku_groups "$ORDERS")
SKU_COUNT=$(printf '%s' "$SKU_GROUPS" | jq 'length')
log "Unique SKUs: ${SKU_COUNT}"

# ── Generate HTML ──────────────────────────────────────────────────────
BATCH_ID=$(generate_batch_id)
HTML_FILE="${PICKLIST_OUTPUT_DIR}/${BATCH_ID}.html"

log "Generating HTML picklist: ${BATCH_ID}..."
generate_picklist_html "$BATCH_ID" "$MODE_LABEL" "$ORDERS" "$SKU_GROUPS" > "$HTML_FILE"
log "HTML saved: ${HTML_FILE}"

# ── Write vault records ────────────────────────────────────────────────
DATE_STR=$(date -u '+%Y-%m-%d')
TS_STR=$(date -u '+%Y-%m-%d %H:%M UTC')
ORDER_IDS_ARR=$(printf '%s' "$ORDERS" | jq '[.[].order_id]')
ORDER_IDS_LIST=$(printf '%s' "$ORDER_IDS_ARR" | jq -r '.[] | "- #\(.)"')

META_CONTENT="---
source: picklist-ops
type: picklist-run
batch_id: ${BATCH_ID}
mode: ${MODE_LABEL}
orders: ${ORDER_COUNT}
skus: ${SKU_COUNT}
date: ${DATE_STR}
generated: ${TS_STR}
status: printed
---

# Picklist ${BATCH_ID}

**Generated:** ${TS_STR}
**Mode:** ${MODE_LABEL}
**Orders:** ${ORDER_COUNT}
**SKUs:** ${SKU_COUNT}

## Orders Included

${ORDER_IDS_LIST}

*HTML: \`07-Marketplace/Warehouse/Picklists/${BATCH_ID}.html\`*"

log "Uploading to vault..."
vault_write "07-Marketplace/Warehouse/Picklists/${BATCH_ID}.md" "$META_CONTENT" || \
  log "Vault metadata write failed (non-fatal)"

# Vault the HTML too for reference (may be large)
vault_write "07-Marketplace/Warehouse/Picklists/${BATCH_ID}.html" "$(cat "$HTML_FILE")" || \
  log "Vault HTML upload failed (non-fatal)"

# ── Update order status to 'picking in progress' ─────────────────────
if [[ -n "${PICKLIST_PICKING_STATUS_ID:-}" ]]; then
  log "Setting orders to picking-in-progress status (${PICKLIST_PICKING_STATUS_ID})..."
  while IFS= read -r oid; do
    bl_set_order_status "$oid" "$PICKLIST_PICKING_STATUS_ID"
  done < <(printf '%s' "$ORDERS" | jq -r '.[].order_id')
fi

# ── Mark orders as printed (state tracking) ───────────────────────────
mark_orders_printed "$ORDER_IDS_ARR"

# ── Physical print (optional) ─────────────────────────────────────────
if [[ -n "${PICKLIST_PRINTER:-}" ]]; then
  log "Sending to printer: ${PICKLIST_PRINTER}..."
  if command -v wkhtmltopdf >/dev/null 2>&1; then
    PDF_FILE="${PICKLIST_OUTPUT_DIR}/${BATCH_ID}.pdf"
    if wkhtmltopdf --quiet --page-size A4 --print-media-type "$HTML_FILE" "$PDF_FILE" 2>/dev/null; then
      lp -d "$PICKLIST_PRINTER" "$PDF_FILE" && log "Printed PDF to ${PICKLIST_PRINTER}" || \
        log "lp failed (non-fatal)"
    else
      log "wkhtmltopdf failed — trying direct HTML print"
      lp -d "$PICKLIST_PRINTER" "$HTML_FILE" || log "lp HTML failed (non-fatal)"
    fi
  else
    lp -d "$PICKLIST_PRINTER" "$HTML_FILE" && log "Printed to ${PICKLIST_PRINTER}" || \
      log "lp failed — no wkhtmltopdf available (non-fatal)"
  fi
else
  log "PICKLIST_PRINTER not set — open ${HTML_FILE} to print manually"
fi

# ── Done ──────────────────────────────────────────────────────────────
batch_window_clear
log "=== picklist-generate: complete ==="
log "  Batch ID : ${BATCH_ID}"
log "  Mode     : ${MODE_LABEL}"
log "  Orders   : ${ORDER_COUNT}"
log "  SKUs     : ${SKU_COUNT}"
log "  File     : ${HTML_FILE}"
