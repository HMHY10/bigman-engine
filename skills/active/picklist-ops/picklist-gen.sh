#!/usr/bin/env bash
# picklist-ops/picklist-gen.sh — HTML picklist generation
# Requires: config.sh, state.sh sourced first
#
# Functions:
#   picklist_gen_qr <data> <output_png>  — generate QR code PNG (or text fallback)
#   picklist_group_by_sku <orders_json>  — group order products by SKU, return JSON
#   picklist_build <pl_id> <type> <orders_json>  — generate HTML file, print path to stdout

# ── picklist_gen_qr <data> <output_png> ──────────────────────────────
# Generate a QR code PNG at output_png encoding <data>.
# Falls back to an empty string (caller handles gracefully) if qrencode missing.
picklist_gen_qr() {
  local data="$1" output="$2"

  if command -v qrencode &>/dev/null; then
    qrencode -o "$output" -s 4 -m 2 "$data" 2>/dev/null && return 0
    log "picklist_gen_qr: qrencode failed for ${data}"
    return 1
  else
    log "picklist_gen_qr: qrencode not installed — QR code will be omitted"
    return 1
  fi
}

# ── _qr_base64 <data> ────────────────────────────────────────────────
# Print base64-encoded PNG of QR code, or empty string if unavailable.
_qr_base64() {
  local data="$1"
  local tmp
  tmp=$(mktemp /tmp/picklist-qr-XXXXXX.png)
  if picklist_gen_qr "$data" "$tmp"; then
    base64 -w 0 "$tmp"
  fi
  rm -f "$tmp"
}

# ── picklist_group_by_sku <orders_json> ──────────────────────────────
# Takes JSON array of BaseLinker order objects.
# Returns JSON object: {sku: {name, location, total_qty, items:[{order_id, qty}]}}
# Orders with multiple products appear once per SKU.
picklist_group_by_sku() {
  local orders="$1"

  printf '%s' "$orders" | jq '
    reduce (.[] | . as $order | .products[]? | . as $prod |
      {
        sku:      ($prod.sku // $prod.product_id // "NO-SKU" | tostring),
        name:     ($prod.name // "Unknown Product"),
        location: ($prod.location // $prod.warehouse_location // "-"),
        order_id: $order.order_id,
        qty:      ($prod.quantity // 1 | tonumber)
      }
    ) as $line (
      {};
      .[$line.sku] //= {name: $line.name, location: $line.location, total_qty: 0, items: []} |
      .[$line.sku].total_qty += $line.qty |
      .[$line.sku].items += [{order_id: $line.order_id, qty: $line.qty}]
    )
  '
}

# ── _html_sku_rows <sku_groups_json> ─────────────────────────────────
# Emit HTML table rows for each SKU group, sorted by location then SKU.
_html_sku_rows() {
  local groups="$1"

  printf '%s' "$groups" | jq -r '
    to_entries |
    sort_by(.value.location, .key) |
    .[] |
    . as $entry |
    "<tr class=\"sku-row\">
      <td class=\"sku\"><strong>\(.key)</strong></td>
      <td class=\"product-name\">\(.value.name)</td>
      <td class=\"location\"><span class=\"bin\">\(.value.location)</span></td>
      <td class=\"qty total-qty\">\(.value.total_qty)</td>
      <td class=\"orders\">\(
        [.value.items[] | "\(.order_id)\u00d7\(.qty)"] | join("<br>")
      )</td>
    </tr>"
  '
}

# ── _count_orders <orders_json> ───────────────────────────────────────
_count_orders() {
  printf '%s' "$1" | jq 'length'
}

# ── _count_skus <sku_groups_json> ─────────────────────────────────────
_count_skus() {
  printf '%s' "$1" | jq 'keys | length'
}

# ── picklist_build <pl_id> <type> <orders_json> ──────────────────────
# Generate a printer-ready HTML picklist.
# Prints path to generated HTML file on stdout.
picklist_build() {
  local pl_id="$1" type="$2" orders_json="$3"
  local html_file="${PICKLIST_HTML_DIR}/${pl_id}.html"

  local order_count sku_groups sku_count
  order_count=$(_count_orders "$orders_json")
  sku_groups=$(picklist_group_by_sku "$orders_json")
  sku_count=$(_count_skus "$sku_groups")

  local generated_at
  generated_at=$(date '+%d %b %Y %H:%M')

  local type_label
  case "$type" in
    overnight) type_label="Overnight Batch" ;;
    daytime)   type_label="Daytime Batch" ;;
    next25)    type_label="Manual — Next 25" ;;
    selected)  type_label="Manual — Selected" ;;
    *)         type_label="$type" ;;
  esac

  # QR code encoding: "PICKLIST:<pl_id>" for scanner identification
  local qr_data="PICKLIST:${pl_id}"
  local qr_b64
  qr_b64=$(_qr_base64 "$qr_data")

  local qr_html
  if [[ -n "$qr_b64" ]]; then
    qr_html="<img src=\"data:image/png;base64,${qr_b64}\" alt=\"QR: ${pl_id}\" class=\"qr-code\">"
  else
    qr_html="<div class=\"qr-fallback\"><strong>${pl_id}</strong><br><small>(scan ID manually)</small></div>"
  fi

  local sku_rows
  sku_rows=$(_html_sku_rows "$sku_groups")

  # Build order-level summary for footer reference
  local order_list
  order_list=$(printf '%s' "$orders_json" | jq -r '
    .[] |
    "#\(.order_id) — \(.delivery_fullname // .buyer_login // "Customer") — \(.delivery_postcode // "") \(.delivery_city // "")"
  ')

  cat > "$html_file" <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Picklist ${pl_id}</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }

    body {
      font-family: Arial, Helvetica, sans-serif;
      font-size: 11pt;
      color: #000;
      background: #fff;
      padding: 12mm 10mm;
    }

    /* ── Header ── */
    .header {
      display: flex;
      justify-content: space-between;
      align-items: flex-start;
      border-bottom: 2px solid #000;
      padding-bottom: 8px;
      margin-bottom: 12px;
    }
    .header-left h1 {
      font-size: 18pt;
      font-weight: 700;
      letter-spacing: 0.5px;
    }
    .header-left .meta {
      font-size: 9pt;
      color: #444;
      margin-top: 4px;
      line-height: 1.6;
    }
    .header-left .type-badge {
      display: inline-block;
      background: #000;
      color: #fff;
      font-size: 8pt;
      font-weight: 700;
      padding: 2px 6px;
      border-radius: 2px;
      margin-top: 4px;
      text-transform: uppercase;
      letter-spacing: 0.5px;
    }
    .header-right {
      text-align: center;
      min-width: 100px;
    }
    .qr-code {
      width: 90px;
      height: 90px;
      border: 1px solid #ccc;
      display: block;
    }
    .qr-fallback {
      width: 90px;
      border: 2px solid #000;
      padding: 8px;
      text-align: center;
      font-size: 8pt;
      line-height: 1.4;
    }
    .header-right .qr-label {
      font-size: 7pt;
      color: #666;
      margin-top: 3px;
    }

    /* ── Summary bar ── */
    .summary-bar {
      display: flex;
      gap: 24px;
      background: #f5f5f5;
      border: 1px solid #ddd;
      padding: 6px 12px;
      margin-bottom: 14px;
      font-size: 10pt;
    }
    .summary-bar .stat strong { font-size: 13pt; display: block; }

    /* ── Picklist table ── */
    table {
      width: 100%;
      border-collapse: collapse;
      margin-bottom: 16px;
    }
    thead th {
      background: #222;
      color: #fff;
      padding: 6px 8px;
      text-align: left;
      font-size: 9pt;
      text-transform: uppercase;
      letter-spacing: 0.4px;
    }
    tbody tr { border-bottom: 1px solid #ddd; }
    tbody tr:nth-child(even) { background: #fafafa; }
    tbody td {
      padding: 7px 8px;
      vertical-align: top;
      font-size: 10pt;
    }
    td.sku { font-family: monospace; font-size: 9.5pt; width: 14%; }
    td.product-name { width: 30%; }
    td.location { width: 12%; }
    td.qty { text-align: center; font-weight: 700; width: 8%; }
    td.total-qty { font-size: 13pt; color: #000; }
    td.orders { font-size: 8.5pt; color: #333; width: 36%; line-height: 1.7; }

    .bin {
      display: inline-block;
      background: #ffe082;
      border: 1px solid #f9a825;
      border-radius: 3px;
      padding: 1px 6px;
      font-weight: 700;
      font-family: monospace;
      font-size: 10pt;
    }

    /* ── Picker checkbox column ── */
    td.check { width: 4%; text-align: center; }
    .checkbox {
      display: inline-block;
      width: 16px;
      height: 16px;
      border: 2px solid #000;
      vertical-align: middle;
    }

    /* ── Order reference footer ── */
    .order-ref {
      font-size: 8pt;
      color: #555;
      border-top: 1px dashed #ccc;
      padding-top: 8px;
      line-height: 1.7;
    }
    .order-ref h3 { font-size: 9pt; margin-bottom: 4px; color: #333; }
    .order-ref pre { font-family: monospace; white-space: pre-wrap; }

    /* ── Print optimisation ── */
    @media print {
      body { padding: 8mm 8mm; }
      .no-print { display: none !important; }
      @page { margin: 10mm; size: A4 portrait; }
      thead { display: table-header-group; }
      tr { page-break-inside: avoid; }
    }

    /* ── Screen-only print button ── */
    .print-btn {
      display: inline-block;
      background: #1a1a1a;
      color: #fff;
      border: none;
      padding: 10px 20px;
      font-size: 11pt;
      cursor: pointer;
      border-radius: 3px;
      margin-bottom: 16px;
    }
    .print-btn:hover { background: #333; }
  </style>
</head>
<body>

  <div class="no-print">
    <button class="print-btn" onclick="window.print()">Print Picklist</button>
  </div>

  <div class="header">
    <div class="header-left">
      <h1>PICKLIST — ${pl_id}</h1>
      <div class="meta">
        Generated: ${generated_at}<br>
        <span class="type-badge">${type_label}</span>
      </div>
    </div>
    <div class="header-right">
      ${qr_html}
      <div class="qr-label">Scan on return</div>
    </div>
  </div>

  <div class="summary-bar">
    <div class="stat"><strong>${order_count}</strong> Orders</div>
    <div class="stat"><strong>${sku_count}</strong> SKUs</div>
    <div class="stat">Picker: ___________________</div>
    <div class="stat">Start: ________ End: ________</div>
  </div>

  <table>
    <thead>
      <tr>
        <th class="check"></th>
        <th class="sku">SKU</th>
        <th class="product-name">Product</th>
        <th class="location">Bin / Location</th>
        <th class="qty">Total Qty</th>
        <th class="orders">Order Breakdown</th>
      </tr>
    </thead>
    <tbody>
$(printf '%s' "$sku_rows" | sed 's/^/<tr class="sku-row">/' | grep -v '^<tr' || printf '%s' "$sku_rows")
    </tbody>
  </table>

  <div class="order-ref">
    <h3>Order Reference</h3>
    <pre>${order_list}</pre>
  </div>

</body>
</html>
HTML

  log "picklist_build: generated ${html_file} (${order_count} orders, ${sku_count} SKUs)"
  printf '%s' "$html_file"
}

# ── picklist_print <html_path> ────────────────────────────────────────
# Send HTML picklist to printer.
# Uses PICKLIST_PRINT_CMD if set (e.g. "lpr -P warehouse_printer").
# Falls back to logging the file path with instructions.
picklist_print() {
  local html_path="$1"

  if [[ -n "${PICKLIST_PRINT_CMD:-}" ]]; then
    log "picklist_print: sending ${html_path} via: ${PICKLIST_PRINT_CMD}"
    eval "${PICKLIST_PRINT_CMD} '${html_path}'" && \
      log "picklist_print: sent to printer OK" && return 0
    log "picklist_print: print command failed for ${html_path}"
    return 1
  else
    log "picklist_print: no PICKLIST_PRINT_CMD set — picklist ready at: ${html_path}"
    log "picklist_print: to auto-print, set PICKLIST_PRINT_CMD in Doppler (e.g. 'lpr -P warehouse')"
    return 0
  fi
}
