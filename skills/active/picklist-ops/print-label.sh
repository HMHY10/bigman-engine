#!/usr/bin/env bash
set -euo pipefail

# picklist-ops/print-label.sh — Retrieve and print shipping label for a single order
#
# Triggered when a pack-station worker scans the QR code on the picklist
# (or called manually). Looks up the order's shipments in BaseLinker,
# downloads the courier label, and sends it to the configured printer.
#
# Usage:
#   doppler run -p shared-services -c prd -- ./print-label.sh ORDER_ID
#
# Requires:
#   BASELINKER_API_TOKEN  (via Doppler)
#   PICKLIST_PRINT_CMD    (optional — shell command to print PDF, e.g. 'lp -d LabelPrinter')

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../marketplace-lib" && pwd)"

source "${LIB_DIR}/config.sh"
source "${LIB_DIR}/baselinker.sh"

ORDER_ID="${1:-}"
if [[ -z "$ORDER_ID" ]]; then
  log "print-label: ORDER_ID required as first argument"
  log "Usage: print-label.sh ORDER_ID"
  exit 1
fi

# Sanitise — order IDs are numeric
ORDER_ID=$(printf '%s' "$ORDER_ID" | tr -cd '0-9')
if [[ -z "$ORDER_ID" ]]; then
  log "print-label: invalid ORDER_ID (must be numeric)"
  exit 1
fi

log "print-label: processing order ${ORDER_ID}"

# ── Get shipments for this order ─────────────────────────────────────────────
PARAMS=$(jq -n --argjson oid "$ORDER_ID" '{order_id: $oid}')
SHIPMENTS_RAW=$(bl_request "getOrderShipments" "$PARAMS" || printf '%s' '{"shipments":[]}')
[[ -z "$SHIPMENTS_RAW" ]] && SHIPMENTS_RAW='{"shipments":[]}'

SHIPMENTS=$(printf '%s' "$SHIPMENTS_RAW" | jq -c '.shipments // []')
SHIPMENT_COUNT=$(printf '%s' "$SHIPMENTS" | jq 'length')
log "print-label: order ${ORDER_ID} — ${SHIPMENT_COUNT} shipment(s)"

if (( SHIPMENT_COUNT == 0 )); then
  log "print-label: no shipments found for order ${ORDER_ID}"
  log "print-label: create a shipment in BaseLinker first, then re-scan"
  # Non-fatal — pack station operator can create the shipment manually
  exit 0
fi

# ── Extract package ID from first shipment ───────────────────────────────────
PACKAGE_ID=$(printf '%s' "$SHIPMENTS" | jq -r '.[0].shipment_id // .[0].package_id // empty')
COURIER=$(printf '%s' "$SHIPMENTS" | jq -r '.[0].courier_code // .[0].courier // "unknown"')

if [[ -z "$PACKAGE_ID" ]]; then
  log "print-label: could not extract package ID from shipment data"
  log "print-label: shipment: $(printf '%s' "$SHIPMENTS" | jq -c '.[0]')"
  exit 1
fi

log "print-label: fetching label — package ${PACKAGE_ID} (${COURIER})"

# ── Fetch label from BaseLinker ──────────────────────────────────────────────
LABEL_PARAMS=$(jq -n \
  --argjson pkg "$PACKAGE_ID" \
  '{package_id: $pkg, page_format: "A6"}')

LABEL_RAW=$(bl_request "getCourierLabel" "$LABEL_PARAMS" || printf '%s' '{}')
[[ -z "$LABEL_RAW" ]] && LABEL_RAW='{}'

LABEL_CONTENTS=$(printf '%s' "$LABEL_RAW" | jq -r '.contents // empty')
LABEL_URL=$(printf '%s' "$LABEL_RAW" | jq -r '.label // .url // empty')

LABEL_FILE="/tmp/label-order${ORDER_ID}-pkg${PACKAGE_ID}.pdf"

# ── Decode / download label ──────────────────────────────────────────────────
if [[ -n "$LABEL_CONTENTS" ]]; then
  # BaseLinker returned base64-encoded PDF content
  printf '%s' "$LABEL_CONTENTS" | base64 -d > "$LABEL_FILE"
  log "print-label: label decoded from base64 — ${LABEL_FILE}"

elif [[ -n "$LABEL_URL" ]]; then
  # BaseLinker returned a URL — download it
  log "print-label: downloading label from ${LABEL_URL}"
  if ! curl -sS --max-time 20 -o "$LABEL_FILE" "$LABEL_URL"; then
    log "print-label: failed to download label from ${LABEL_URL}"
    exit 1
  fi
  log "print-label: label downloaded — ${LABEL_FILE}"

else
  log "print-label: BaseLinker returned no label data or URL for package ${PACKAGE_ID}"
  log "print-label: raw response: $(printf '%s' "$LABEL_RAW" | jq -c '.')"
  exit 1
fi

# ── Send to printer ──────────────────────────────────────────────────────────
PRINT_CMD="${PICKLIST_PRINT_CMD:-}"

if [[ -n "$PRINT_CMD" ]]; then
  log "print-label: printing — ${PRINT_CMD} ${LABEL_FILE}"
  if $PRINT_CMD "$LABEL_FILE"; then
    log "print-label: label sent to printer for order ${ORDER_ID}"
  else
    log "print-label: print command failed — label is at ${LABEL_FILE}"
    exit 1
  fi
else
  log "print-label: PICKLIST_PRINT_CMD not set"
  log "print-label: label saved at ${LABEL_FILE} — print manually: lp ${LABEL_FILE}"
fi

log "print-label: done for order ${ORDER_ID}"
