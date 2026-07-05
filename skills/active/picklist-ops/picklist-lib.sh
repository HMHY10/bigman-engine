#!/usr/bin/env bash
# picklist-ops/picklist-lib.sh — Shared constants and helpers for picklist operations
# Source this after config.sh, cache.sh, and baselinker.sh from marketplace-lib.

# ── Status IDs (BaseLinker) ────────────────────────────────────────────
# Set these via Doppler secrets or environment variables.
# Find status IDs at: BaseLinker → Orders → Statuses
PICKLIST_READY_STATUS_ID="${PICKLIST_READY_STATUS_ID:-}"          # "Ready to Pick" status
PICKLIST_PICKING_STATUS_ID="${PICKLIST_PICKING_STATUS_ID:-}"      # Set when picklist generated (leave empty to skip)
PICKLIST_DISPATCHED_STATUS_ID="${PICKLIST_DISPATCHED_STATUS_ID:-}" # Set after label scanned at pack station

# ── Courier / Printer Config ───────────────────────────────────────────
PICKLIST_DEFAULT_COURIER="${PICKLIST_DEFAULT_COURIER:-}"          # BaseLinker courier_code for auto label creation
PICKLIST_PRINTER="${PICKLIST_PRINTER:-}"                          # CUPS printer name for picklist pages
PICKLIST_LABEL_PRINTER="${PICKLIST_LABEL_PRINTER:-}"              # CUPS printer name for shipping labels

# ── Batch Settings ─────────────────────────────────────────────────────
PICKLIST_BATCH_SIZE="${PICKLIST_BATCH_SIZE:-25}"
PICKLIST_BATCH_WINDOW_MINUTES="${PICKLIST_BATCH_WINDOW_MINUTES:-60}"
PICKLIST_SINCE_HOURS="${PICKLIST_SINCE_HOURS:-72}"
PICKLIST_MORNING_SINCE_HOURS="${PICKLIST_MORNING_SINCE_HOURS:-14}"

# ── Paths ──────────────────────────────────────────────────────────────
PICKLIST_STATE_DIR="${STATE_BASE:-/opt/bigman-engine/state}/picklist-ops"
PICKLIST_OUTPUT_DIR="/opt/bigman-engine/picklists"
BIGMAN_HOST="${BIGMAN_HOST:-http://localhost:3000}"

# ── Init ───────────────────────────────────────────────────────────────
picklist_init() {
  mkdir -p "$PICKLIST_STATE_DIR" "$PICKLIST_OUTPUT_DIR"
}

# ── Batch window state management ─────────────────────────────────────

batch_window_start_epoch() {
  local f="${PICKLIST_STATE_DIR}/batch-window-start"
  [[ -f "$f" ]] && cat "$f" || echo 0
}

batch_window_set() {
  printf '%d' "$(date +%s)" > "${PICKLIST_STATE_DIR}/batch-window-start"
  log "picklist: batch window started at $(date -u '+%H:%M:%S UTC')"
}

batch_window_clear() {
  rm -f "${PICKLIST_STATE_DIR}/batch-window-start"
}

batch_window_expired() {
  local start elapsed
  start=$(batch_window_start_epoch)
  (( start == 0 )) && return 1
  elapsed=$(( ($(date +%s) - start) / 60 ))
  (( elapsed >= PICKLIST_BATCH_WINDOW_MINUTES ))
}

batch_window_minutes_elapsed() {
  local start
  start=$(batch_window_start_epoch)
  (( start == 0 )) && echo 0 && return
  echo $(( ($(date +%s) - start) / 60 ))
}

# ── Printed orders tracking ────────────────────────────────────────────

PRINTED_ORDERS_FILE="${PICKLIST_STATE_DIR}/printed-orders.json"

printed_orders_load() {
  [[ -f "$PRINTED_ORDERS_FILE" ]] && cat "$PRINTED_ORDERS_FILE" || printf '[]'
}

mark_orders_printed() {
  local order_ids_json="$1"
  local existing new_list
  existing=$(printed_orders_load)
  new_list=$(printf '%s\n%s' "$existing" "$order_ids_json" | jq -s 'add | unique')
  printf '%s' "$new_list" > "$PRINTED_ORDERS_FILE"
  log "picklist: marked $(printf '%s' "$order_ids_json" | jq 'length') orders as printed"
}

expire_printed_orders() {
  if [[ -f "$PRINTED_ORDERS_FILE" ]]; then
    local count
    count=$(jq 'length' < "$PRINTED_ORDERS_FILE")
    if (( count > 500 )); then
      jq '.[-500:]' < "$PRINTED_ORDERS_FILE" > "${PRINTED_ORDERS_FILE}.tmp" && \
        mv "${PRINTED_ORDERS_FILE}.tmp" "$PRINTED_ORDERS_FILE"
      log "picklist: trimmed printed-orders list to 500 entries"
    fi
  fi
}

# ── BaseLinker: update order status ───────────────────────────────────

bl_set_order_status() {
  local order_id="$1" status_id="$2"
  [[ -z "$status_id" ]] && return 0
  local params
  params=$(jq -n --argjson oid "$order_id" --argjson sid "$status_id" \
    '{order_id: $oid, status_id: $sid}')
  bl_request "setOrderStatus" "$params" > /dev/null 2>&1 || true
  log "picklist: order ${order_id} → status ${status_id}"
}

# ── Build SKU-grouped structure from orders ────────────────────────────
# Input:  JSON array of BaseLinker order objects
# Output: sorted JSON array [{sku, name, total_qty, orders:[{order_id,customer,qty}]}]
build_sku_groups() {
  local orders_json="$1"
  printf '%s' "$orders_json" | jq -c '
    [
      .[] | . as $order |
      ($order.products // [])[] |
      {
        sku:      (.sku // .storage_product_id // (.product_id | tostring) // "UNKNOWN"),
        name:     (.name // "Unknown Product"),
        qty:      ((.quantity // "1") | tonumber),
        order_id: $order.order_id,
        customer: ($order.delivery_fullname // $order.invoice_fullname // "Customer")
      }
    ] |
    group_by(.sku) |
    map(
      . as $items |
      {
        sku:       $items[0].sku,
        name:      $items[0].name,
        total_qty: ($items | map(.qty) | add),
        orders: (
          $items |
          group_by(.order_id) |
          map({
            order_id: .[0].order_id,
            customer: .[0].customer,
            qty:      (map(.qty) | add)
          })
        )
      }
    ) |
    sort_by(.sku)
  '
}

# ── Generate unique batch ID ───────────────────────────────────────────
generate_batch_id() {
  date -u '+%Y%m%d-%H%M%S'
}

# ── Resolve since-timestamp (cross-platform: GNU date + BSD date) ─────
since_epoch() {
  local hours="$1"
  date -d "-${hours} hours" +%s 2>/dev/null || \
  date -v "-${hours}H"      +%s 2>/dev/null || \
  echo $(( $(date +%s) - hours * 3600 ))
}

# ── Generate picklist HTML ─────────────────────────────────────────────
# Args: batch_id mode_label orders_json sku_groups_json
generate_picklist_html() {
  local batch_id="$1"
  local mode_label="$2"
  local orders_json="$3"
  local sku_groups="$4"

  local order_count sku_count dt_str
  order_count=$(printf '%s' "$orders_json" | jq 'length')
  sku_count=$(printf '%s' "$sku_groups" | jq 'length')
  dt_str=$(date -u '+%Y-%m-%d %H:%M UTC')

  # ── HTML header ──────────────────────────────────────────────────────
  cat <<HTMLHEAD
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Pick List — ${batch_id}</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: Arial, sans-serif; font-size: 12px; color: #222; background: #fff; }
    .page-header { padding: 12px 20px; border-bottom: 3px solid #333; background: #f8f8f8; }
    .page-header h1 { font-size: 20px; display: inline-block; margin-right: 16px; }
    .meta { color: #555; font-size: 11px; margin-top: 4px; }
    .badge { display: inline-block; background: #333; color: #fff; padding: 2px 8px;
             border-radius: 3px; font-size: 10px; margin-right: 6px; text-transform: uppercase; }
    .section-title { font-size: 14px; font-weight: bold; padding: 9px 16px;
                     background: #eee; border-top: 2px solid #bbb; border-bottom: 1px solid #ccc; }
    /* ── SKU blocks ── */
    .sku-block { border: 1px solid #ccc; margin: 8px 14px; page-break-inside: avoid; }
    .sku-header { background: #f3f3f3; padding: 7px 10px; border-bottom: 1px solid #ccc;
                  display: flex; align-items: baseline; gap: 10px; flex-wrap: wrap; }
    .sku-code { font-family: monospace; font-weight: bold; font-size: 12px; color: #333; }
    .sku-name { flex: 1; min-width: 120px; }
    .sku-total { font-weight: bold; font-size: 15px; color: #c00; white-space: nowrap; }
    .sku-table { width: 100%; border-collapse: collapse; }
    .sku-table th { background: #eaeaea; text-align: left; padding: 4px 8px;
                    font-size: 11px; border-bottom: 1px solid #ccc; }
    .sku-table td { padding: 4px 8px; border-bottom: 1px solid #eee; vertical-align: top; }
    .sku-table tr:last-child td { border-bottom: none; }
    .qty-cell { font-weight: bold; text-align: center; width: 40px; }
    /* ── Order cards ── */
    .order-card { border: 1px solid #ccc; margin: 8px 14px; page-break-inside: avoid;
                  display: flex; }
    .order-card-body { flex: 1; padding: 10px 14px; }
    .order-id { font-weight: bold; font-size: 14px; }
    .order-customer { font-size: 12px; color: #333; margin: 3px 0; }
    .order-address { font-size: 10px; color: #888; margin-bottom: 7px; }
    .items-table { width: 100%; border-collapse: collapse; margin-top: 4px; }
    .items-table th { background: #f3f3f3; text-align: left; padding: 3px 6px;
                      font-size: 10px; border-bottom: 1px solid #ddd; }
    .items-table td { padding: 3px 6px; border-bottom: 1px solid #f0f0f0; font-size: 11px; }
    .items-table .qty-cell { width: 30px; }
    .order-card-qr { width: 200px; min-width: 200px; padding: 10px; text-align: center;
                     border-left: 1px dashed #ccc; background: #fafafa;
                     display: flex; flex-direction: column; align-items: center; justify-content: center; }
    .order-card-qr img { width: 180px; height: 180px; }
    .qr-label { font-size: 9px; color: #888; margin-top: 4px; line-height: 1.4; }
    /* ── Misc ── */
    .print-btn { display: block; margin: 14px auto; padding: 8px 26px; background: #333;
                 color: #fff; border: none; cursor: pointer; font-size: 13px; border-radius: 3px; }
    .section-divider { border: none; border-top: 4px dashed #ccc; margin: 20px 0; }
    @media print {
      .print-btn { display: none; }
      .section-divider { page-break-after: always; border: none; }
    }
  </style>
</head>
<body>

<div class="page-header">
  <h1>ArryBarry — Pick List</h1>
  <span class="badge">${mode_label}</span>
  <span class="badge">${order_count} orders</span>
  <span class="badge">${sku_count} SKUs</span>
  <div class="meta">Batch: ${batch_id} &nbsp;|&nbsp; Generated: ${dt_str}</div>
</div>

<button class="print-btn" onclick="window.print()">Print This Picklist</button>

<!-- ================================================================== -->
<!--  SECTION 1: PICKING GUIDE — walk the warehouse grouped by SKU      -->
<!-- ================================================================== -->

<div class="section-title">Section 1 — Picking Guide (Grouped by SKU)</div>

HTMLHEAD

  # ── SKU blocks via jq ───────────────────────────────────────────────
  printf '%s' "$sku_groups" | jq -r '
    .[] |
    "<div class=\"sku-block\">" +
    "<div class=\"sku-header\">" +
      "<span class=\"sku-code\">" + (.sku | @html) + "</span>" +
      "<span class=\"sku-name\">"  + (.name | @html) + "</span>" +
      "<span class=\"sku-total\">TOTAL: " + (.total_qty | tostring) + "</span>" +
    "</div>" +
    "<table class=\"sku-table\">" +
    "<thead><tr><th>Order #</th><th>Customer</th><th class=\"qty-cell\">Qty</th></tr></thead>" +
    "<tbody>" +
    ( .orders | map(
        "<tr><td>#" + (.order_id | tostring) + "</td><td>" +
        (.customer | @html) + "</td><td class=\"qty-cell\">" +
        (.qty | tostring) + "</td></tr>"
    ) | join("")) +
    "</tbody></table></div>"
  '

  # ── Section 2 divider ────────────────────────────────────────────────
  cat <<SECTION2

<hr class="section-divider">

<!-- ================================================================== -->
<!--  SECTION 2: DISPATCH CARDS — scan QR code at pack station          -->
<!-- ================================================================== -->

<div class="section-title">Section 2 — Dispatch Cards (Scan QR Code to Print Shipping Label)</div>

SECTION2

  # ── Order dispatch cards via jq ─────────────────────────────────────
  printf '%s' "$orders_json" | jq -r --arg host "$BIGMAN_HOST" '
    .[] |
    . as $o |
    ($o.order_id | tostring) as $oid |
    ($host + "/webhook?action=print-label&order_id=" + $oid) as $label_url |
    "<div class=\"order-card\">" +
    "<div class=\"order-card-body\">" +
      "<div class=\"order-id\">Order #" + $oid + "</div>" +
      "<div class=\"order-customer\">" +
        (($o.delivery_fullname // $o.invoice_fullname // "Customer") | @html) +
      "</div>" +
      "<div class=\"order-address\">" +
        (($o.delivery_address // "") + ", " +
         ($o.delivery_city // "") + " " +
         ($o.delivery_postcode // "") | @html) +
      "</div>" +
      "<table class=\"items-table\">" +
      "<thead><tr><th>SKU</th><th>Product</th><th class=\"qty-cell\">Qty</th></tr></thead>" +
      "<tbody>" +
      ( ($o.products // []) | map(
          "<tr><td>" + ((.sku // .storage_product_id // "-") | @html) + "</td><td>" +
          ((.name // "Product") | @html) + "</td><td class=\"qty-cell\">" +
          ((.quantity // "1") | tostring) + "</td></tr>"
      ) | join("")) +
      "</tbody></table>" +
    "</div>" +
    "<div class=\"order-card-qr\">" +
      "<img src=\"https://chart.googleapis.com/chart?chs=180x180&amp;cht=qr&amp;chld=M%7C0&amp;chl=" +
      ($label_url | @uri) + "\" alt=\"Scan to print label for order " + $oid + "\">" +
      "<div class=\"qr-label\">Scan to print label<br>#" + $oid + "</div>" +
    "</div>" +
    "</div>"
  '

  # ── Footer ────────────────────────────────────────────────────────────
  cat <<HTMLFOOT

<button class="print-btn" onclick="window.print()">Print This Picklist</button>

</body>
</html>
HTMLFOOT
}
