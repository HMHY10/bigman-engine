#!/usr/bin/env bash
set -euo pipefail

# picklist-ops/label-trigger.sh — Shipping label print trigger
#
# Fired when a warehouse operative scans the QR code on a dispatch card at the pack station.
# The QR code encodes: ${BIGMAN_HOST}/webhook?action=print-label&order_id=ORDER_ID
#
# This script:
#   1. Fetches the order from BaseLinker
#   2. Checks for an existing shipping package (avoids duplicate labels)
#   3. Creates a package via BaseLinker if none exists (requires PICKLIST_DEFAULT_COURIER)
#   4. Fetches the label PDF URL from BaseLinker
#   5. Prints to the label printer (requires PICKLIST_LABEL_PRINTER + CUPS)
#   6. Advances the order to PICKLIST_DISPATCHED_STATUS_ID
#
# Usage:
#   label-trigger.sh <order_id>
#   label-trigger.sh "order_id=12345"              (query-string format from webhook body)
#   label-trigger.sh '{"order_id": 12345}'         (JSON format)
#   echo "order_id=12345" | label-trigger.sh        (stdin fallback)
#
# Runs as: doppler run -p shared-services -c prd -- ./label-trigger.sh <input>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../marketplace-lib" && pwd)"

source "${LIB_DIR}/config.sh"
source "${LIB_DIR}/cache.sh"
source "${LIB_DIR}/baselinker.sh"
source "${LIB_DIR}/alerts.sh"
source "${SCRIPT_DIR}/picklist-lib.sh"

# ── Parse order_id from various input formats ──────────────────────────
INPUT="${1:-}"

# Try stdin if no argument provided
if [[ -z "$INPUT" ]] && ! [ -t 0 ]; then
  INPUT=$(cat)
fi

ORDER_ID=""

# JSON: {"order_id": 12345} or {"action":"print-label","order_id":"12345"}
if printf '%s' "$INPUT" | jq -e '.order_id' >/dev/null 2>&1; then
  ORDER_ID=$(printf '%s' "$INPUT" | jq -r '.order_id | tostring')
# Query string: order_id=12345&... or action=print-label&order_id=12345
elif [[ "$INPUT" =~ order_id=([0-9]+) ]]; then
  ORDER_ID="${BASH_REMATCH[1]}"
# Plain numeric ID
elif [[ "$INPUT" =~ ^[0-9]+$ ]]; then
  ORDER_ID="$INPUT"
fi

# Strip any non-numeric residue
ORDER_ID=$(printf '%s' "$ORDER_ID" | tr -cd '0-9')

if [[ -z "$ORDER_ID" ]]; then
  log "label-trigger: ERROR — could not extract order_id from input: '${INPUT}'"
  exit 1
fi

log "=== label-trigger: order ${ORDER_ID} ==="

# ── Fetch order ────────────────────────────────────────────────────────
ORDER_RESULT=$(bl_request "getOrders" "$(jq -n --argjson id "$ORDER_ID" '{order_id: $id}')") || {
  log "label-trigger: failed to fetch order ${ORDER_ID} from BaseLinker"
  exit 1
}

ORDER=$(printf '%s' "$ORDER_RESULT" | jq -c '.orders[0] // empty')
if [[ -z "$ORDER" ]]; then
  log "label-trigger: order ${ORDER_ID} not found"
  exit 1
fi

CUSTOMER=$(printf '%s' "$ORDER" | jq -r '.delivery_fullname // .invoice_fullname // "Customer"')
log "Order ${ORDER_ID}: ${CUSTOMER}"

# ── Check for existing packages ────────────────────────────────────────
PKG_RESULT=$(bl_request "getOrderPackages" \
  "$(jq -n --argjson id "$ORDER_ID" '{order_id: $id}')" 2>/dev/null || printf '{"packages":[]}')
PACKAGES=$(printf '%s' "$PKG_RESULT" | jq '.packages // []')
PKG_COUNT=$(printf '%s' "$PACKAGES" | jq 'length')
log "Existing shipping packages: ${PKG_COUNT}"

PACKAGE_ID=""

if (( PKG_COUNT > 0 )); then
  PACKAGE_ID=$(printf '%s' "$PACKAGES" | jq -r '.[0].package_id // .[0].id // empty')
  log "Using existing package: ${PACKAGE_ID}"
else
  # No package exists — create one if courier is configured
  if [[ -z "${PICKLIST_DEFAULT_COURIER:-}" ]]; then
    log "label-trigger: PICKLIST_DEFAULT_COURIER not set — cannot auto-create package for order ${ORDER_ID}"
    log "Create the package manually in BaseLinker, then rescan the QR code"
    # Still advance status so the order isn't stuck
    bl_set_order_status "$ORDER_ID" "${PICKLIST_DISPATCHED_STATUS_ID:-}" || true
    exit 0
  fi

  log "Creating shipping package (courier=${PICKLIST_DEFAULT_COURIER})..."
  CREATE_PARAMS=$(jq -n \
    --argjson order_id "$ORDER_ID" \
    --arg courier "$PICKLIST_DEFAULT_COURIER" \
    '{order_id: $order_id, courier_code: $courier, fields: {}}')

  CREATE_RESULT=$(bl_request "createPackage" "$CREATE_PARAMS") || {
    log "label-trigger: failed to create package for order ${ORDER_ID}"
    exit 1
  }

  PACKAGE_ID=$(printf '%s' "$CREATE_RESULT" | jq -r '.package_id // empty')
  if [[ -z "$PACKAGE_ID" ]]; then
    log "label-trigger: package created but no package_id in response"
    exit 1
  fi
  log "Package created: ${PACKAGE_ID}"
fi

# ── Fetch label ────────────────────────────────────────────────────────
if [[ -n "$PACKAGE_ID" ]]; then
  log "Fetching label for package ${PACKAGE_ID}..."
  LABEL_RESULT=$(bl_request "getCourierLabel" \
    "$(jq -n --argjson pkg_id "$PACKAGE_ID" '{package_id: $pkg_id, label_format: "PDF"}')" \
    2>/dev/null || printf '{}')

  # BaseLinker returns label as base64 or URL depending on courier
  LABEL_URL=$(printf '%s' "$LABEL_RESULT" | jq -r '.label // .label_url // empty')
  LABEL_B64=$(printf '%s' "$LABEL_RESULT" | jq -r '.label_base64 // empty')

  if [[ -n "$LABEL_URL" || -n "$LABEL_B64" ]]; then
    LABEL_FILE="/tmp/label-order-${ORDER_ID}-pkg-${PACKAGE_ID}.pdf"

    # Materialise the label PDF
    if [[ -n "$LABEL_URL" ]]; then
      log "Downloading label from URL..."
      curl -sS -o "$LABEL_FILE" "$LABEL_URL" || {
        log "label-trigger: failed to download label PDF"
        LABEL_FILE=""
      }
    elif [[ -n "$LABEL_B64" ]]; then
      log "Decoding base64 label..."
      printf '%s' "$LABEL_B64" | base64 -d > "$LABEL_FILE" 2>/dev/null || {
        log "label-trigger: failed to decode base64 label"
        LABEL_FILE=""
      }
    fi

    # Print the label
    if [[ -n "$LABEL_FILE" && -s "$LABEL_FILE" ]]; then
      if [[ -n "${PICKLIST_LABEL_PRINTER:-}" ]]; then
        log "Printing label to ${PICKLIST_LABEL_PRINTER}..."
        lp -d "$PICKLIST_LABEL_PRINTER" "$LABEL_FILE" && \
          log "Label printed for order ${ORDER_ID}" || \
          log "lp command failed (non-fatal) — label at ${LABEL_FILE}"
      else
        log "PICKLIST_LABEL_PRINTER not set — label saved at ${LABEL_FILE}"
        log "Set PICKLIST_LABEL_PRINTER in Doppler to enable auto-print"
      fi
      rm -f "$LABEL_FILE"
    fi
  else
    log "label-trigger: no label data returned from BaseLinker for package ${PACKAGE_ID}"
    log "Generate the label manually in BaseLinker if needed"
  fi
fi

# ── Advance order status to dispatched ───────────────────────────────
if [[ -n "${PICKLIST_DISPATCHED_STATUS_ID:-}" ]]; then
  bl_set_order_status "$ORDER_ID" "$PICKLIST_DISPATCHED_STATUS_ID"
fi

log "=== label-trigger: complete — order ${ORDER_ID} ==="
