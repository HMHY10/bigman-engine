#!/usr/bin/env bash
# picklist-ops/generate.sh — Picklist HTML generation with SKU grouping and QR codes
# Requires: config.sh, state.sh sourced first
#
# Usage: generate_picklist <orders_json_array> <batch_number> <mode_label>
# Writes HTML to /tmp/picklist-<batch>.html
# Prints path to the generated file on stdout.

PICKLIST_OUTPUT_DIR="${STATE_BASE}/picklist-ops/output"

# ── _qr_base64 <text> ─────────────────────────────────────────────────
# Generate a QR code PNG and return it as a base64-encoded data URI.
# Falls back to a text placeholder if qrencode is not available.
_qr_base64() {
  local text="$1"
  local tmp_png
  tmp_png=$(mktemp /tmp/qr-XXXXXX.png)

  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t PNG -s 4 -m 2 -o "$tmp_png" "$text" 2>/dev/null
    local b64
    b64=$(base64 -w 0 < "$tmp_png" 2>/dev/null || base64 < "$tmp_png")
    rm -f "$tmp_png"
    printf 'data:image/png;base64,%s' "$b64"
  else
    rm -f "$tmp_png"
    # Inline SVG placeholder when qrencode is unavailable
    local svg
    svg='<svg xmlns="http://www.w3.org/2000/svg" width="60" height="60"><rect width="60" height="60" fill="#eee"/><text x="5" y="35" font-size="8" fill="#999">QR</text></svg>'
    printf 'data:image/svg+xml;base64,%s' "$(printf '%s' "$svg" | base64 -w 0 2>/dev/null || printf '%s' "$svg" | base64)"
  fi
}

# ── _escape_html <string> ─────────────────────────────────────────────
_escape_html() {
  printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'
}

# ── generate_picklist <orders_json> <batch_num> <mode_label> ─────────
# Produces a self-contained HTML picklist, grouped by SKU.
# Returns path to the HTML file.
generate_picklist() {
  local orders_json="$1"
  local batch_num="$2"
  local mode_label="${3:-auto}"

  mkdir -p "$PICKLIST_OUTPUT_DIR"

  local order_count
  order_count=$(printf '%s' "$orders_json" | jq 'length')
  local date_str
  date_str=$(date '+%Y-%m-%d')
  local time_str
  time_str=$(date '+%H:%M')
  local ts_str
  ts_str=$(date '+%Y-%m-%d %H:%M:%S')
  local out_file="${PICKLIST_OUTPUT_DIR}/picklist-${date_str}-batch${batch_num}.html"

  log "generate: building picklist for ${order_count} orders (batch ${batch_num}, mode: ${mode_label})"

  # ── Build SKU group data ───────────────────────────────────────────
  # Produces a JSON object keyed by sku:
  # { "SKU-001": { "name": "...", "total_qty": N, "orders": [ {order_id, order_ref, qty}, ... ] }, ... }
  local sku_groups
  sku_groups=$(printf '%s' "$orders_json" | jq -c '
    reduce .[] as $order (
      {};
      reduce ($order.products // [] | .[]) as $product (
        .;
        ($product.sku // $product.storage_default_location // ("NOSKU-" + ($product.product_id | tostring))) as $sku |
        ($product.name // "Unknown Product") as $name |
        (($product.quantity // 1) | tonumber) as $qty |
        ($order.order_id | tostring) as $oid |
        ($order.order_id | tostring) as $oref |
        if .[$sku] then
          .[$sku].total_qty += $qty |
          .[$sku].orders += [{order_id: $oid, order_ref: $oref, qty: $qty}]
        else
          .[$sku] = {name: $name, sku: $sku, total_qty: $qty, orders: [{order_id: $oid, order_ref: $oref, qty: $qty}]}
        end
      )
    )
    | to_entries
    | sort_by(.key)
    | from_entries
  ')

  local sku_count
  sku_count=$(printf '%s' "$sku_groups" | jq 'keys | length')
  local total_units
  total_units=$(printf '%s' "$sku_groups" | jq '[.[].total_qty] | add // 0')

  log "generate: ${sku_count} distinct SKUs, ${total_units} total units"

  # ── Build QR codes for each order ID ─────────────────────────────
  # Pre-generate all unique order QR codes as base64 data URIs
  declare -A QR_CACHE
  local all_order_ids
  all_order_ids=$(printf '%s' "$orders_json" | jq -r '.[].order_id | tostring' | sort -u)

  while IFS= read -r oid; do
    [[ -z "$oid" ]] && continue
    local qr_url="${THEPOPEBOT_URL:-http://localhost:3000}/api/picklist/print-label?order_id=${oid}"
    QR_CACHE["$oid"]=$(_qr_base64 "$qr_url")
    log "generate: QR for order ${oid} ready"
  done <<< "$all_order_ids"

  # ── Build HTML ────────────────────────────────────────────────────
  local html_file
  html_file="$out_file"

  # Write HTML header
  cat > "$html_file" <<HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Picklist — Batch ${batch_num} — ${date_str}</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: 'Courier New', Courier, monospace; font-size: 11pt; color: #111; background: #fff; }
  .page-header { border-bottom: 3px solid #111; padding: 8px 12px 6px; margin-bottom: 12px; }
  .page-header h1 { font-size: 16pt; font-weight: bold; }
  .page-header .meta { font-size: 9pt; color: #555; margin-top: 2px; }
  .page-header .stats { font-size: 10pt; margin-top: 4px; }
  .sku-group { margin-bottom: 16px; border: 1px solid #333; page-break-inside: avoid; }
  .sku-header { background: #111; color: #fff; padding: 5px 10px; display: flex; justify-content: space-between; align-items: center; }
  .sku-header .sku-code { font-size: 12pt; font-weight: bold; letter-spacing: 0.5px; }
  .sku-header .sku-name { font-size: 10pt; font-weight: normal; opacity: 0.85; margin-left: 10px; }
  .sku-header .sku-total { font-size: 14pt; font-weight: bold; white-space: nowrap; }
  .order-table { width: 100%; border-collapse: collapse; }
  .order-table th { background: #eee; border-bottom: 1px solid #999; padding: 4px 8px; font-size: 9pt; text-align: left; }
  .order-table td { border-bottom: 1px solid #ddd; padding: 5px 8px; vertical-align: middle; }
  .order-table tr:last-child td { border-bottom: none; }
  .order-table tr:nth-child(even) td { background: #f9f9f9; }
  .order-id { font-weight: bold; font-size: 11pt; }
  .order-qty { font-size: 13pt; font-weight: bold; text-align: right; }
  .order-qr { text-align: center; }
  .order-qr img { width: 60px; height: 60px; }
  .check-col { width: 28px; }
  .check-box { width: 20px; height: 20px; border: 2px solid #333; display: inline-block; }
  .footer { margin-top: 20px; font-size: 8pt; color: #999; border-top: 1px solid #ddd; padding-top: 6px; }
  @media print {
    body { font-size: 10pt; }
    .sku-group { page-break-inside: avoid; }
    .page-header { page-break-after: avoid; }
  }
</style>
</head>
<body>

<div class="page-header">
  <h1>PICKLIST — Batch #${batch_num}</h1>
  <div class="meta">Generated: ${ts_str} &nbsp;|&nbsp; Mode: $(printf '%s' "$mode_label" | tr '[:lower:]' '[:upper:]') &nbsp;|&nbsp; Print and work top-to-bottom by SKU</div>
  <div class="stats">
    <strong>${order_count} orders</strong> &nbsp;&bull;&nbsp;
    <strong>${sku_count} SKUs</strong> &nbsp;&bull;&nbsp;
    <strong>${total_units} total units</strong>
  </div>
</div>

HTMLEOF

  # Write each SKU group
  while IFS= read -r sku_entry; do
    [[ -z "$sku_entry" ]] && continue

    local sku name total_qty orders_in_group
    sku=$(printf '%s' "$sku_entry" | jq -r '.key')
    name=$(printf '%s' "$sku_entry" | jq -r '.value.name // "Unknown"')
    total_qty=$(printf '%s' "$sku_entry" | jq -r '.value.total_qty')
    orders_in_group=$(printf '%s' "$sku_entry" | jq -c '.value.orders')
    local sku_safe
    sku_safe=$(_escape_html "$sku")
    local name_safe
    name_safe=$(_escape_html "$name")

    cat >> "$html_file" <<SKUEOF
<div class="sku-group">
  <div class="sku-header">
    <span>
      <span class="sku-code">${sku_safe}</span>
      <span class="sku-name">${name_safe}</span>
    </span>
    <span class="sku-total">${total_qty} units</span>
  </div>
  <table class="order-table">
    <thead>
      <tr>
        <th class="check-col"></th>
        <th>Order ID</th>
        <th style="width:120px">Qty to Pick</th>
        <th style="width:70px">Label QR</th>
      </tr>
    </thead>
    <tbody>
SKUEOF

    while IFS= read -r order_row; do
      [[ -z "$order_row" ]] && continue
      local row_oid row_qty
      row_oid=$(printf '%s' "$order_row" | jq -r '.order_id')
      row_qty=$(printf '%s' "$order_row" | jq -r '.qty')
      local qr_data="${QR_CACHE[$row_oid]:-}"

      cat >> "$html_file" <<ROWEOF
      <tr>
        <td class="check-col"><span class="check-box"></span></td>
        <td class="order-id">#${row_oid}</td>
        <td class="order-qty">${row_qty}</td>
        <td class="order-qr">
ROWEOF

      if [[ -n "$qr_data" ]]; then
        printf '          <img src="%s" alt="QR #%s" title="Scan to print label for order %s">\n' \
          "$qr_data" "$row_oid" "$row_oid" >> "$html_file"
      else
        printf '          <span style="font-size:8pt;color:#aaa">QR N/A</span>\n' >> "$html_file"
      fi

      cat >> "$html_file" <<ROWEOF2
        </td>
      </tr>
ROWEOF2

    done < <(printf '%s' "$orders_in_group" | jq -c '.[]')

    cat >> "$html_file" <<ENDSKU
    </tbody>
  </table>
</div>

ENDSKU

  done < <(printf '%s' "$sku_groups" | jq -c 'to_entries[]')

  # Write order index summary at the bottom
  cat >> "$html_file" <<SUMMARYEOF
<div class="footer">
  <strong>Order Index</strong> (${order_count} orders in this batch):<br>
SUMMARYEOF

  printf '%s' "$orders_json" | jq -r '
    .[] |
    "#\(.order_id)  \(.delivery_fullname // .email // "")  \(.products // [] | map("\(.quantity)x \(.name // .sku // "?")") | join(", "))"
  ' | while IFS= read -r line; do
    printf '  %s<br>\n' "$(_escape_html "$line")" >> "$html_file"
  done

  cat >> "$html_file" <<FOOTEREOF
  <br>
  <em>ArryBarry Health &amp; Beauty &mdash; picklist-ops &mdash; ${ts_str}</em>
</div>
</body>
</html>
FOOTEREOF

  log "generate: picklist written to ${html_file}"
  printf '%s' "$html_file"
}
