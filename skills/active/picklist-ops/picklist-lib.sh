#!/usr/bin/env bash
# picklist-ops/picklist-lib.sh — Shared library for picklist generation
# Requires: marketplace-lib/config.sh, baselinker.sh, alerts.sh sourced first

# ── State helpers ──────────────────────────────────────────────────────

picklist_state_init() {
  mkdir -p "$PICKLIST_STATE_DIR"
}

# Read printed order IDs array (JSON array of integers)
picklist_get_printed_orders() {
  local file="${PICKLIST_STATE_DIR}/printed-orders.json"
  if [[ -f "$file" ]]; then
    cat "$file"
  else
    printf '[]'
  fi
}

# Append order IDs to the printed list
picklist_mark_printed() {
  local order_ids_json="$1"  # JSON array of order IDs
  local file="${PICKLIST_STATE_DIR}/printed-orders.json"
  local existing
  existing=$(picklist_get_printed_orders)
  # Merge and deduplicate
  local merged
  merged=$(printf '%s\n%s' "$existing" "$order_ids_json" | jq -s 'add | unique | sort')
  printf '%s' "$merged" > "$file"
  log "picklist_mark_printed: marked $(printf '%s' "$order_ids_json" | jq 'length') orders as printed"
}

# Get/set the batch timer
picklist_get_timer() {
  local file="${PICKLIST_STATE_DIR}/timer.json"
  [[ -f "$file" ]] && cat "$file" || printf 'null'
}

picklist_set_timer() {
  local count="$1"
  local file="${PICKLIST_STATE_DIR}/timer.json"
  printf '{"started_at":%d,"order_count":%d}\n' "$(date +%s)" "$count" > "$file"
  log "picklist_set_timer: started at $(date -u '+%Y-%m-%dT%H:%M:%SZ') with ${count} orders"
}

picklist_clear_timer() {
  rm -f "${PICKLIST_STATE_DIR}/timer.json"
  log "picklist_clear_timer: timer cleared"
}

# ── Order fetching ─────────────────────────────────────────────────────

# Get ready orders, excluding already-printed ones.
# Returns JSON array of order objects.
picklist_get_ready_orders() {
  local limit="${1:-0}"  # 0 = no limit
  local since="${2:-0}"  # epoch, 0 = use default 24h window

  if [[ "$since" -eq 0 ]]; then
    since=$(( $(date +%s) - 86400 ))  # last 24h as fallback window
  fi

  log "picklist_get_ready_orders: fetching orders with status ${PICKLIST_READY_STATUS_ID} since ${since}"

  local all_orders
  all_orders=$(bl_get_orders "$since" "$PICKLIST_READY_STATUS_ID" || printf '[]')
  [[ -z "$all_orders" || "$all_orders" == "null" ]] && all_orders="[]"

  # Filter out already-printed orders
  local printed
  printed=$(picklist_get_printed_orders)

  local ready_orders
  ready_orders=$(printf '%s' "$all_orders" | jq --argjson printed "$printed" \
    '[.[] | select(.order_id as $id | ($printed | index($id)) == null)]')

  local count
  count=$(printf '%s' "$ready_orders" | jq 'length')
  log "picklist_get_ready_orders: ${count} ready orders (excluding already printed)"

  if [[ "$limit" -gt 0 ]]; then
    ready_orders=$(printf '%s' "$ready_orders" | jq --argjson n "$limit" '.[:$n]')
  fi

  printf '%s' "$ready_orders"
}

# ── Picklist generation ────────────────────────────────────────────────

# Generate batch ID
picklist_batch_id() {
  local type="${1:-manual}"
  printf 'PICKLIST-%s-%s' "$(date -u '+%Y%m%d-%H%M%S')" "$type"
}

# Group orders by SKU and generate HTML picklist.
# Args: $1 = JSON array of full order objects, $2 = batch_id, $3 = batch_type
# Writes HTML to vault and saves batch JSON to state dir.
# Returns: batch_id
picklist_generate() {
  local orders_json="$1"
  local batch_id="${2:-$(picklist_batch_id)}"
  local batch_type="${3:-manual}"

  local order_count
  order_count=$(printf '%s' "$orders_json" | jq 'length')
  log "picklist_generate: generating picklist for ${order_count} orders (batch=${batch_id})"

  if [[ "$order_count" -eq 0 ]]; then
    log "picklist_generate: no orders, skipping"
    return 0
  fi

  local date_str ts_str
  date_str=$(date -u '+%d %b %Y')
  ts_str=$(date -u '+%H:%M UTC')

  # ── Group by SKU ──────────────────────────────────────────────────────
  # Each order has .products[] with .storage_id, .product_id, .name, .sku,
  # .quantity. We group by product_id (or sku if available).
  local sku_groups
  sku_groups=$(printf '%s' "$orders_json" | jq -c '
    # Flatten: one entry per (order, product line)
    [.[] | . as $order |
      (.products // []) | .[] |
      {
        product_id: (.product_id // .storage_product_id // "unknown"),
        sku:        (.sku // .product_id // "N/A"),
        name:       (.name // "Unknown product"),
        order_id:   $order.order_id,
        order_date: ($order.date_add // 0),
        platform:   ($order.order_source // "unknown"),
        customer:   ($order.delivery_fullname // $order.invoice_fullname // "N/A"),
        quantity:   (.quantity // 1)
      }
    ] |
    # Group by product_id
    group_by(.product_id) |
    map({
      product_id: .[0].product_id,
      sku:        .[0].sku,
      name:       .[0].name,
      total_qty:  (map(.quantity | tonumber) | add),
      lines:      .
    }) |
    sort_by(.name)')

  local group_count
  group_count=$(printf '%s' "$sku_groups" | jq 'length')
  log "picklist_generate: ${group_count} distinct SKU groups"

  # ── Save batch state ──────────────────────────────────────────────────
  local order_ids
  order_ids=$(printf '%s' "$orders_json" | jq '[.[].order_id]')

  local batch_json
  batch_json=$(jq -n \
    --arg id "$batch_id" \
    --arg type "$batch_type" \
    --argjson order_ids "$order_ids" \
    --argjson orders "$orders_json" \
    --argjson groups "$sku_groups" \
    --argjson created "$(date +%s)" \
    '{
      batch_id:    $id,
      type:        $type,
      created_at:  $created,
      order_count: ($order_ids | length),
      order_ids:   $order_ids,
      sku_groups:  $groups
    }')

  printf '%s' "$batch_json" > "${PICKLIST_STATE_DIR}/${batch_id}.json"
  log "picklist_generate: batch state saved to ${PICKLIST_STATE_DIR}/${batch_id}.json"

  # ── Generate HTML picklist ────────────────────────────────────────────
  local html_content
  html_content=$(picklist_render_html "$sku_groups" "$batch_id" "$batch_type" \
    "$date_str" "$ts_str" "$order_count")

  # Write to vault
  local vault_path="07-Marketplace/Picklists/${batch_id}.html"
  local http_code
  http_code=$(curl -sS -o /dev/null -w '%{http_code}' \
    -X PUT "${VAULT_URL}/vault/${vault_path}" \
    -H "Authorization: Bearer ${OBSIDIAN_API_KEY}" \
    -H "Content-Type: text/html" \
    -d "$html_content")

  if [[ "$http_code" == "204" || "$http_code" == "200" ]]; then
    log "picklist_generate: vault write OK — ${vault_path}"
  else
    log "picklist_generate: vault write failed (HTTP ${http_code}) — continuing"
  fi

  # Mark orders as printed
  picklist_mark_printed "$order_ids"
  picklist_clear_timer

  printf '%s' "$batch_id"
}

# Render the printable HTML for a picklist batch.
picklist_render_html() {
  local sku_groups="$1"
  local batch_id="$2"
  local batch_type="$3"
  local date_str="$4"
  local ts_str="$5"
  local order_count="$6"
  local scan_base="${PICKLIST_SCAN_BASE_URL:-}"

  # Build SKU section HTML
  local sku_sections=""
  while IFS= read -r group; do
    [[ -z "$group" ]] && continue

    local sku name total_qty
    sku=$(printf '%s' "$group" | jq -r '.sku')
    name=$(printf '%s' "$group" | jq -r '.name')
    total_qty=$(printf '%s' "$group" | jq -r '.total_qty')

    local rows=""
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      local order_id qty platform customer
      order_id=$(printf '%s' "$line" | jq -r '.order_id')
      qty=$(printf '%s' "$line" | jq -r '.quantity')
      platform=$(printf '%s' "$line" | jq -r '.platform')
      customer=$(printf '%s' "$line" | jq -r '.customer')

      # QR encodes the scan URL for this order
      local qr_data="${scan_base}/api/picklist/scan?order_id=${order_id}"
      local qr_url="https://api.qrserver.com/v1/create-qr-code/?size=80x80&margin=2&data=$(printf '%s' "$qr_data" | jq -rR @uri)"

      rows="${rows}
      <tr>
        <td class=\"order-id\">#${order_id}</td>
        <td class=\"platform\">${platform}</td>
        <td class=\"customer\">${customer}</td>
        <td class=\"qty\">${qty}</td>
        <td class=\"qr\"><img src=\"${qr_url}\" alt=\"Order ${order_id}\" width=\"80\" height=\"80\"></td>
      </tr>"
    done < <(printf '%s' "$group" | jq -c '.lines[]')

    sku_sections="${sku_sections}
    <div class=\"sku-section\">
      <div class=\"sku-header\">
        <span class=\"sku-badge\">${sku}</span>
        <span class=\"sku-name\">${name}</span>
        <span class=\"sku-total\">Total qty: <strong>${total_qty}</strong></span>
      </div>
      <table>
        <thead>
          <tr>
            <th>Order</th>
            <th>Platform</th>
            <th>Customer</th>
            <th>Qty</th>
            <th>Scan to print label</th>
          </tr>
        </thead>
        <tbody>
          ${rows}
        </tbody>
      </table>
    </div>"
  done < <(printf '%s' "$sku_groups" | jq -c '.[]')

  local type_label
  case "$batch_type" in
    morning) type_label="Morning Batch" ;;
    auto)    type_label="Auto Batch" ;;
    *)       type_label="Manual Batch" ;;
  esac

  cat <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Picklist — ${batch_id}</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: 'Arial', sans-serif;
      font-size: 11pt;
      color: #000;
      background: #fff;
      padding: 12mm 15mm;
    }
    .header {
      border-bottom: 2px solid #000;
      padding-bottom: 6px;
      margin-bottom: 14px;
      display: flex;
      justify-content: space-between;
      align-items: flex-end;
    }
    .header h1 { font-size: 18pt; font-weight: 700; letter-spacing: -0.5px; }
    .header .meta { text-align: right; font-size: 9pt; color: #444; }
    .header .meta strong { font-size: 11pt; color: #000; }
    .badge {
      display: inline-block;
      background: #000;
      color: #fff;
      font-size: 8pt;
      font-weight: 700;
      padding: 2px 6px;
      border-radius: 3px;
      margin-left: 6px;
      vertical-align: middle;
    }
    .sku-section {
      margin-bottom: 14px;
      break-inside: avoid;
      page-break-inside: avoid;
    }
    .sku-header {
      background: #f0f0f0;
      border: 1px solid #ccc;
      border-bottom: none;
      padding: 5px 8px;
      display: flex;
      align-items: center;
      gap: 10px;
    }
    .sku-badge {
      font-family: monospace;
      font-weight: 700;
      font-size: 10pt;
      background: #333;
      color: #fff;
      padding: 2px 6px;
      border-radius: 3px;
    }
    .sku-name {
      flex: 1;
      font-weight: 600;
      font-size: 11pt;
    }
    .sku-total {
      font-size: 9pt;
      color: #444;
    }
    table {
      width: 100%;
      border-collapse: collapse;
      font-size: 10pt;
    }
    thead th {
      background: #333;
      color: #fff;
      text-align: left;
      padding: 4px 8px;
      font-size: 9pt;
      font-weight: 600;
    }
    tbody tr { border-bottom: 1px solid #ddd; }
    tbody tr:nth-child(even) { background: #fafafa; }
    tbody td { padding: 4px 8px; vertical-align: middle; }
    td.order-id { font-family: monospace; font-weight: 700; font-size: 10pt; }
    td.qty {
      font-size: 12pt;
      font-weight: 700;
      text-align: center;
      width: 60px;
    }
    td.qr { text-align: center; width: 96px; }
    td.qr img { display: block; margin: 2px auto; }
    td.platform { font-size: 9pt; color: #444; width: 100px; }
    td.customer { font-size: 9pt; max-width: 180px; overflow: hidden; text-overflow: ellipsis; }
    .footer {
      margin-top: 16px;
      border-top: 1px solid #ccc;
      padding-top: 6px;
      font-size: 8pt;
      color: #888;
      text-align: center;
    }
    @media print {
      body { padding: 8mm 10mm; }
      .no-print { display: none !important; }
    }
  </style>
</head>
<body>
  <div class="header">
    <div>
      <h1>ArryBarry Picklist <span class="badge">${type_label}</span></h1>
      <div style="margin-top:4px;font-size:9pt;color:#444;">Batch ID: ${batch_id}</div>
    </div>
    <div class="meta">
      <div><strong>${date_str}</strong> &nbsp; ${ts_str}</div>
      <div style="margin-top:4px;">${order_count} orders &nbsp;|&nbsp; $(printf '%s' "$sku_groups" | jq 'length') SKUs</div>
    </div>
  </div>

  ${sku_sections}

  <div class="footer">
    Scan QR code at pack station to print shipping label &nbsp;|&nbsp; Generated by ArryBarry BigMan Engine &nbsp;|&nbsp; ${batch_id}
  </div>

  <script>
    // Auto-trigger print dialog if opened directly in browser
    if (window.location.search.includes('autoprint=1')) {
      window.onload = function() { window.print(); };
    }
  </script>
</body>
</html>
HTML
}
