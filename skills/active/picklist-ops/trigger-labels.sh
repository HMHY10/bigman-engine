#!/usr/bin/env bash
set -euo pipefail

# picklist-ops/trigger-labels.sh — Pack station QR scan handler
#
# Called when a picklist QR code is scanned at the pack station.
# Receives a picklist_id, looks up its orders, and creates shipping
# packages (labels) in BaseLinker for each order.
#
# Usage:
#   trigger-labels.sh <picklist_id>
#   trigger-labels.sh '{"picklist_id":"042"}'  (JSON body from webhook)
#
# Runs as: doppler run -p shared-services -c prd -- bash ./skills/active/picklist-ops/trigger-labels.sh <args>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../marketplace-lib" && pwd)"

source "${LIB_DIR}/config.sh"
source "${LIB_DIR}/cache.sh"
source "${LIB_DIR}/baselinker.sh"
source "${LIB_DIR}/alerts.sh"

# ── Configuration ─────────────────────────────────────────────────────
PICKLIST_PACKED_STATUS_ID="${PICKLIST_PACKED_STATUS_ID:-}"
PICKLIST_DEFAULT_COURIER="${PICKLIST_DEFAULT_COURIER:-dpd}"

STATE_DIR="${STATE_BASE}/picklist-ops"

# ── Parse picklist_id from argument ──────────────────────────────────
RAW_ARG="${1:-}"
PICKLIST_ID=""

if [[ -z "$RAW_ARG" ]]; then
  log "ERROR: No argument provided. Usage: trigger-labels.sh <picklist_id|json_body>"
  exit 1
fi

# Support both plain ID ("042") and JSON body ('{"picklist_id":"042"}')
if printf '%s' "$RAW_ARG" | jq -e . &>/dev/null; then
  PICKLIST_ID=$(printf '%s' "$RAW_ARG" | jq -r '.picklist_id // .id // empty')
else
  PICKLIST_ID="$RAW_ARG"
fi

if [[ -z "$PICKLIST_ID" ]]; then
  log "ERROR: Could not extract picklist_id from: ${RAW_ARG}"
  exit 1
fi

log "=== picklist-ops/trigger-labels: picklist #${PICKLIST_ID} ==="

# ── Load picklist state ───────────────────────────────────────────────
STATE_FILE="${STATE_DIR}/picklists/${PICKLIST_ID}.json"

if [[ ! -f "$STATE_FILE" ]]; then
  log "ERROR: State file not found: ${STATE_FILE}"
  alert_create "high" "baselinker" "Picklists/Alerts" \
    "Label Trigger Failed — Picklist #${PICKLIST_ID}" \
    "Pack station scan received for picklist #${PICKLIST_ID} but no state file found.

Check that the picklist was generated correctly and state is intact."
  exit 1
fi

PICKLIST_STATE=$(cat "$STATE_FILE")
PICKLIST_STATUS=$(printf '%s' "$PICKLIST_STATE" | jq -r '.status')
ORDER_IDS=$(printf '%s' "$PICKLIST_STATE" | jq -c '.order_ids')
ORDER_COUNT=$(printf '%s' "$ORDER_IDS" | jq 'length')

log "Picklist status: ${PICKLIST_STATUS} | Orders: ${ORDER_COUNT}"

# ── Guard against double-firing ───────────────────────────────────────
if [[ "$PICKLIST_STATUS" == "labels_printed" ]]; then
  log "Labels already printed for picklist #${PICKLIST_ID} — ignoring duplicate scan"
  exit 0
fi

# ── Create packages for each order ───────────────────────────────────
DATE_STR=$(date '+%Y-%m-%d')
TS_STR=$(date '+%Y-%m-%d %H:%M:%S')

PRINTED_ORDERS="[]"
FAILED_ORDERS="[]"
SUCCESS_COUNT=0
FAIL_COUNT=0

while IFS= read -r order_id; do
  [[ -z "$order_id" ]] && continue
  log "Creating package for order ${order_id} via ${PICKLIST_DEFAULT_COURIER}..."

  PACKAGE_RESULT=$(bl_create_package "$order_id" "$PICKLIST_DEFAULT_COURIER" 2>/dev/null || echo "")

  if [[ -z "$PACKAGE_RESULT" ]]; then
    log "  FAILED: no response for order ${order_id}"
    FAILED_ORDERS=$(printf '%s' "$FAILED_ORDERS" | jq --arg oid "$order_id" \
      '. + [{order_id: $oid, error: "no response from BaseLinker"}]')
    FAIL_COUNT=$((FAIL_COUNT + 1))
    continue
  fi

  BL_STATUS=$(printf '%s' "$PACKAGE_RESULT" | jq -r '.status // "ERROR"')
  if [[ "$BL_STATUS" == "ERROR" ]]; then
    ERR_MSG=$(printf '%s' "$PACKAGE_RESULT" | jq -r '.error_message // "unknown error"')
    log "  FAILED: order ${order_id} — ${ERR_MSG}"
    FAILED_ORDERS=$(printf '%s' "$FAILED_ORDERS" | jq \
      --arg oid "$order_id" --arg err "$ERR_MSG" \
      '. + [{order_id: $oid, error: $err}]')
    FAIL_COUNT=$((FAIL_COUNT + 1))
    continue
  fi

  PACKAGE_ID=$(printf '%s' "$PACKAGE_RESULT" | jq -r '.package_id // empty')
  log "  OK: package ${PACKAGE_ID} created for order ${order_id}"

  PRINTED_ORDERS=$(printf '%s' "$PRINTED_ORDERS" | jq \
    --arg oid "$order_id" --arg pkg "$PACKAGE_ID" \
    '. + [{order_id: $oid, package_id: $pkg}]')
  SUCCESS_COUNT=$((SUCCESS_COUNT + 1))

  # Set order to packed status
  if [[ -n "${PICKLIST_PACKED_STATUS_ID:-}" ]]; then
    bl_set_order_status "$order_id" "$PICKLIST_PACKED_STATUS_ID" \
      && log "  Status updated to packed for order ${order_id}" \
      || log "  WARNING: failed to update status for order ${order_id}"
  fi

done < <(printf '%s' "$ORDER_IDS" | jq -r '.[]')

log "Label creation complete: ${SUCCESS_COUNT} OK, ${FAIL_COUNT} failed"

# ── Update picklist state ─────────────────────────────────────────────
local_state_update=$(printf '%s' "$PICKLIST_STATE" | jq \
  --arg status "labels_printed" \
  --arg ts "$TS_STR" \
  --argjson printed "$PRINTED_ORDERS" \
  --argjson failed "$FAILED_ORDERS" \
  '. + {
    status: $status,
    labels_printed_at: $ts,
    printed_orders: $printed,
    failed_orders: $failed
  }')
printf '%s' "$local_state_update" > "$STATE_FILE"

# ── Write vault report ────────────────────────────────────────────────
# Build order rows for report
PRINTED_ROWS=""
while IFS= read -r entry; do
  [[ -z "$entry" ]] && continue
  oid=$(printf '%s' "$entry" | jq -r '.order_id')
  pkg=$(printf '%s' "$entry" | jq -r '.package_id')
  PRINTED_ROWS="${PRINTED_ROWS}| #${oid} | ${pkg} | ✅ |
"
done < <(printf '%s' "$PRINTED_ORDERS" | jq -c '.[]')

FAILED_ROWS=""
while IFS= read -r entry; do
  [[ -z "$entry" ]] && continue
  oid=$(printf '%s' "$entry" | jq -r '.order_id')
  err=$(printf '%s' "$entry" | jq -r '.error')
  FAILED_ROWS="${FAILED_ROWS}| #${oid} | — | ❌ ${err} |
"
done < <(printf '%s' "$FAILED_ORDERS" | jq -c '.[]')

VAULT_PATH="07-Marketplace/Picklists/${DATE_STR}-labels-${PICKLIST_ID}.md"

REPORT_CONTENT=$(cat <<REPORT_EOF
---
source: picklist-ops
type: label-print-report
picklist_id: "${PICKLIST_ID}"
date: "${DATE_STR}"
scanned_at: "${TS_STR}"
orders_total: ${ORDER_COUNT}
labels_printed: ${SUCCESS_COUNT}
labels_failed: ${FAIL_COUNT}
---

# Label Print Report — Picklist #${PICKLIST_ID}

**Scanned at pack station:** ${TS_STR}
**Total orders:** ${ORDER_COUNT} | **Labels printed:** ${SUCCESS_COUNT} | **Failed:** ${FAIL_COUNT}

## Printed Labels

| Order | Package ID | Status |
|-------|-----------|--------|
${PRINTED_ROWS}
$(if [[ -n "$FAILED_ROWS" ]]; then
printf '%s\n%s\n' "## Failed Orders" "| Order | Package ID | Error |
|-------|-----------|-------|
${FAILED_ROWS}"
fi)
---
*Generated by picklist-ops trigger-labels · ${TS_STR}*
REPORT_EOF
)

vault_write "$VAULT_PATH" "$REPORT_CONTENT" \
  && log "Label report written to vault: ${VAULT_PATH}" \
  || log "WARNING: vault write failed for label report"

# ── Alert on failures ─────────────────────────────────────────────────
if (( FAIL_COUNT > 0 )); then
  alert_create "high" "baselinker" "Picklists/Alerts" \
    "Label Creation Failures — Picklist #${PICKLIST_ID}" \
    "**Picklist:** #${PICKLIST_ID}
**Scanned at:** ${TS_STR}
**Labels printed:** ${SUCCESS_COUNT}/${ORDER_COUNT}
**Failed:** ${FAIL_COUNT}

$(printf '%s' "$FAILED_ORDERS" | jq -r '.[] | "- Order #\(.order_id): \(.error)"')"
fi

log "=== picklist-ops/trigger-labels: done (${SUCCESS_COUNT}/${ORDER_COUNT} labels) ==="
