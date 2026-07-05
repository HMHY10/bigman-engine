#!/usr/bin/env bash
set -euo pipefail

# picklist-ops/run.sh — Warehouse picklist automation for ArryBarry
#
# Usage:
#   run.sh overnight                     — pre-open batch (all overnight orders, SKU-grouped, no cap)
#   run.sh daytime                       — rolling ~25-order daytime batching with time fallback
#   run.sh print-next-25                 — manual: print the next batch of up to 25 queued orders
#   run.sh print-selected <id> [id…]     — manual: print a batch for specific order IDs
#   run.sh scan-return <picklist_id>     — print shipping labels for a returned picklist
#
# Requires: doppler run -p shared-services -c prd -- ./run.sh <cmd>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../marketplace-lib" && pwd)"

source "${LIB_DIR}/config.sh"
source "${LIB_DIR}/cache.sh"
source "${LIB_DIR}/baselinker.sh"
source "${LIB_DIR}/alerts.sh"

# ══════════════════════════════════════════════════════════════════════
# CONFIGURATION
# ══════════════════════════════════════════════════════════════════════

# BaseLinker order status IDs — must be set in Doppler
PICKLIST_ORDER_STATUS_ID="${PICKLIST_ORDER_STATUS_ID:-}"   # "ready to pick"
PICKLIST_MARKED_STATUS_ID="${PICKLIST_MARKED_STATUS_ID:-}" # "on picklist"
PICKLIST_PICKED_STATUS_ID="${PICKLIST_PICKED_STATUS_ID:-}" # "picked"

# Printer names (CUPS)
PICKLIST_PRINTER="${PICKLIST_PRINTER:-picklist}"
SHIPPING_LABEL_PRINTER="${SHIPPING_LABEL_PRINTER:-label}"

# Batching
WAREHOUSE_OPEN_HOUR="${WAREHOUSE_OPEN_HOUR:-8}"
PICKLIST_BATCH_SIZE="${PICKLIST_BATCH_SIZE:-25}"
PICKLIST_BATCH_TIMEOUT_MINS="${PICKLIST_BATCH_TIMEOUT_MINS:-30}"

# Product location field name in BaseLinker inventory extra fields
PICKLIST_LOCATION_FIELD="${PICKLIST_LOCATION_FIELD:-location}"

# Output directories
PICKLIST_OUTPUT_DIR="${PICKLIST_OUTPUT_DIR:-/opt/bigman-engine/picklists}"
STATE_DIR="${STATE_BASE}/picklist-ops"
BATCHES_DIR="${STATE_DIR}/batches"

mkdir -p "$STATE_DIR" "$BATCHES_DIR" "$PICKLIST_OUTPUT_DIR"

# ══════════════════════════════════════════════════════════════════════
# HELPERS — STATE
# ══════════════════════════════════════════════════════════════════════

# Read queued orders JSON array (orders fetched but not yet batched)
_queue_read() {
  local f="${STATE_DIR}/queued-orders.json"
  if [[ -f "$f" ]]; then
    cat "$f"
  else
    printf '[]'
  fi
}

# Write queued orders JSON array
_queue_write() {
  printf '%s' "$1" > "${STATE_DIR}/queued-orders.json"
}

# Append one or more orders (JSON array) to the queue, deduplicating by order_id
_queue_add() {
  local new_orders="$1"
  local current
  current=$(_queue_read)
  local merged
  merged=$(printf '%s\n%s' "$current" "$new_orders" | \
    jq -s 'add | unique_by(.order_id)')
  _queue_write "$merged"
  local count
  count=$(printf '%s' "$merged" | jq 'length')
  log "queue: ${count} orders total after merge"
}

# Remove orders from queue by order_id list (JSON array of IDs)
_queue_remove() {
  local ids_json="$1"
  local current
  current=$(_queue_read)
  local updated
  updated=$(printf '%s' "$current" | \
    jq --argjson ids "$ids_json" '[.[] | select(.order_id as $oid | $ids | index($oid) | not)]')
  _queue_write "$updated"
  log "queue: removed $(printf '%s' "$ids_json" | jq 'length') orders"
}

# Get the last order fetch epoch (0 = never fetched)
_last_fetch_read() {
  local f="${STATE_DIR}/last-fetch.txt"
  [[ -f "$f" ]] && cat "$f" || printf '0'
}

_last_fetch_write() {
  printf '%s' "$1" > "${STATE_DIR}/last-fetch.txt"
}

# Generate next picklist ID: PL-YYYYMMDD-NNN
_next_picklist_id() {
  local date_str
  date_str=$(date '+%Y%m%d')
  local counter_file="${STATE_DIR}/batch-counter.txt"
  local last_date_file="${STATE_DIR}/batch-counter-date.txt"

  # Reset counter if it's a new day
  local last_date="00000000"
  [[ -f "$last_date_file" ]] && last_date=$(cat "$last_date_file")
  local counter=0
  if [[ "$last_date" == "$date_str" ]] && [[ -f "$counter_file" ]]; then
    counter=$(cat "$counter_file")
  fi

  counter=$((counter + 1))
  printf '%s' "$date_str" > "$last_date_file"
  printf '%s' "$counter" > "$counter_file"

  printf 'PL-%s-%03d' "$date_str" "$counter"
}

# Read a batch manifest; returns {} if not found
_batch_read() {
  local id="$1"
  local f="${BATCHES_DIR}/${id}.json"
  [[ -f "$f" ]] && cat "$f" || printf '{}'
}

# Write a batch manifest
_batch_write() {
  local id="$1" json="$2"
  printf '%s' "$json" > "${BATCHES_DIR}/${id}.json"
}

# Get epoch of when the current open batch started (0 = no open batch)
_batch_timer_read() {
  local f="${STATE_DIR}/batch-timer.json"
  [[ -f "$f" ]] && jq -r '.started_at // 0' "$f" || printf '0'
}

_batch_timer_write() {
  printf '{"started_at":%d}' "$(date +%s)" > "${STATE_DIR}/batch-timer.json"
}

_batch_timer_clear() {
  rm -f "${STATE_DIR}/batch-timer.json"
}

# ══════════════════════════════════════════════════════════════════════
# HELPERS — FETCH ORDERS
# ══════════════════════════════════════════════════════════════════════

# Fetch orders in PICKLIST_ORDER_STATUS_ID since last fetch and add to queue
_fetch_new_orders() {
  if [[ -z "$PICKLIST_ORDER_STATUS_ID" ]]; then
    log "fetch: PICKLIST_ORDER_STATUS_ID not set — skipping order fetch"
    return 0
  fi

  local last_fetch
  last_fetch=$(_last_fetch_read)
  local now
  now=$(date +%s)

  # For overnight run, look back at least 16 hours to catch everything since last close
  local since="$last_fetch"
  if [[ "$since" == "0" ]]; then
    since=$((now - 86400))  # default: last 24h on first run
    log "fetch: first run, looking back 24h (since $(date -d @$since '+%Y-%m-%d %H:%M'))"
  else
    log "fetch: fetching orders since $(date -d @$since '+%Y-%m-%d %H:%M')"
  fi

  local orders
  orders=$(bl_get_orders "$since" "$PICKLIST_ORDER_STATUS_ID") || {
    log "fetch: bl_get_orders failed"
    return 1
  }

  local count
  count=$(printf '%s' "$orders" | jq 'length')
  log "fetch: ${count} orders with status ${PICKLIST_ORDER_STATUS_ID}"

  if (( count > 0 )); then
    _queue_add "$orders"
    # Mark orders as "on picklist" status if configured
    if [[ -n "$PICKLIST_MARKED_STATUS_ID" ]]; then
      _mark_orders_status "$orders" "$PICKLIST_MARKED_STATUS_ID"
    fi
  fi

  _last_fetch_write "$now"
}

# Set BaseLinker order status for all orders in a JSON array
_mark_orders_status() {
  local orders_json="$1" status_id="$2"
  local count
  count=$(printf '%s' "$orders_json" | jq 'length')
  log "status: marking ${count} orders → status ${status_id}"

  while IFS= read -r order_id; do
    [[ -z "$order_id" ]] && continue
    local params
    params=$(jq -n --argjson oid "$order_id" --argjson sid "$status_id" \
      '{order_id: $oid, status_id: $sid}')
    bl_request "setOrderStatus" "$params" > /dev/null 2>&1 || \
      log "status: failed to update order ${order_id}"
  done < <(printf '%s' "$orders_json" | jq -r '.[].order_id')
}

# ══════════════════════════════════════════════════════════════════════
# HELPERS — PRODUCT LOCATIONS
# ══════════════════════════════════════════════════════════════════════

# Given a JSON array of product_ids, return a map: {product_id: "location_string"}
_get_product_locations() {
  local product_ids_json="$1"
  local count
  count=$(printf '%s' "$product_ids_json" | jq 'length')

  if (( count == 0 )); then
    printf '{}'
    return 0
  fi

  # We need an inventory_id — use the first inventory available
  local inv_id
  local inventories_raw
  inventories_raw=$(bl_request "getInventories" "{}") || { printf '{}'; return 0; }
  inv_id=$(printf '%s' "$inventories_raw" | jq -r '.inventories[0].inventory_id // empty')

  if [[ -z "$inv_id" ]]; then
    log "locations: no inventory found, skipping location lookup"
    printf '{}'
    return 0
  fi

  # Batch into groups of 100
  local location_map="{}"
  local batch_ids="" batch_count=0

  _flush_location_batch() {
    [[ -z "$batch_ids" ]] && return
    local params
    params=$(printf '{"inventory_id": %s, "products": [%s]}' "$inv_id" "$batch_ids")
    local result
    result=$(bl_request "getInventoryProductsData" "$params" 2>/dev/null) || {
      log "locations: batch fetch failed"
      return
    }
    # Extract location field from each product
    local batch_map
    batch_map=$(printf '%s' "$result" | jq --arg field "$PICKLIST_LOCATION_FIELD" \
      '[.products // {} | to_entries[] |
        {key: .key,
         value: (
           (.value.extra_fields // {})[$field] //
           .value.location //
           ""
         )}] | from_entries')
    location_map=$(printf '%s\n%s' "$location_map" "$batch_map" | jq -s 'add')
    batch_ids=""
    batch_count=0
  }

  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    if [[ -n "$batch_ids" ]]; then
      batch_ids="${batch_ids},${pid}"
    else
      batch_ids="${pid}"
    fi
    batch_count=$((batch_count + 1))
    (( batch_count >= 100 )) && _flush_location_batch
  done < <(printf '%s' "$product_ids_json" | jq -r '.[]')

  _flush_location_batch
  printf '%s' "$location_map"
}

# ══════════════════════════════════════════════════════════════════════
# HELPERS — PICKLIST GENERATION
# ══════════════════════════════════════════════════════════════════════

# Generate picklist HTML and print it.
# Args: $1 = picklist_id, $2 = JSON array of orders
# Returns: 0 on success
_generate_and_print_picklist() {
  local picklist_id="$1"
  local orders="$2"
  local order_count
  order_count=$(printf '%s' "$orders" | jq 'length')

  log "generate: creating picklist ${picklist_id} (${order_count} orders)"

  # ── Collect all unique product IDs ──────────────────────────────────
  local product_ids
  product_ids=$(printf '%s' "$orders" | jq \
    '[.[].products // [] | .[].product_id | select(. != null and . != "")] | unique')

  # ── Fetch bin/location data ──────────────────────────────────────────
  local location_map
  location_map=$(_get_product_locations "$product_ids")
  log "generate: got locations for $(printf '%s' "$location_map" | jq 'keys | length') products"

  # ── Build SKU-grouped structure ──────────────────────────────────────
  # Result: {sku: {sku, name, total_qty, location, orders: [{order_id, qty, channel, ...}]}}
  local sku_groups
  sku_groups=$(printf '%s' "$orders" | \
    jq --argjson locs "$location_map" '
    [
      .[] as $order |
      ($order.products // [])[] as $prod |
      {
        sku:      ($prod.sku // $prod.product_id // "NO-SKU"),
        name:     ($prod.name // "Unknown product"),
        qty:      (($prod.quantity // 1) | tonumber),
        order_id: $order.order_id,
        channel:  ($order.order_source // "unknown"),
        location: ($locs[($prod.product_id | tostring)] // "")
      }
    ] |
    group_by(.sku) |
    map({
      sku:       .[0].sku,
      name:      .[0].name,
      location:  .[0].location,
      total_qty: (map(.qty) | add),
      orders:    [.[] | {order_id, qty, channel}]
    }) |
    sort_by(.location, .sku)
  ')

  local sku_count
  sku_count=$(printf '%s' "$sku_groups" | jq 'length')
  log "generate: ${sku_count} unique SKUs across ${order_count} orders"

  # ── Generate QR code (encodes picklist ID) ───────────────────────────
  local qr_png="${PICKLIST_OUTPUT_DIR}/${picklist_id}-qr.png"
  local qr_b64=""
  if command -v qrencode &>/dev/null; then
    qrencode -o "$qr_png" -s 8 -m 2 "$picklist_id" 2>/dev/null && \
      qr_b64=$(base64 -w 0 "$qr_png" 2>/dev/null) && \
      rm -f "$qr_png"
  else
    log "generate: qrencode not found — QR code will be omitted"
  fi

  # ── Build HTML picklist ──────────────────────────────────────────────
  local generated_at
  generated_at=$(date '+%d %b %Y %H:%M')
  local html_file="${PICKLIST_OUTPUT_DIR}/${picklist_id}.html"

  # Build SKU group rows (bash string building, no external deps)
  local sku_rows=""
  while IFS= read -r group; do
    local sku name total_qty location order_rows

    sku=$(printf '%s' "$group" | jq -r '.sku')
    name=$(printf '%s' "$group" | jq -r '.name')
    total_qty=$(printf '%s' "$group" | jq -r '.total_qty')
    location=$(printf '%s' "$group" | jq -r '.location // ""')

    # Build per-order rows within this SKU group
    order_rows=""
    while IFS= read -r order_entry; do
      local oid oqty ochan
      oid=$(printf '%s' "$order_entry" | jq -r '.order_id')
      oqty=$(printf '%s' "$order_entry" | jq -r '.qty')
      ochan=$(printf '%s' "$order_entry" | jq -r '.channel')
      order_rows="${order_rows}
          <tr>
            <td>${oid}</td>
            <td>${ochan}</td>
            <td class=\"qty\">${oqty}</td>
            <td class=\"pick-cell\"><span class=\"pick-box\"></span></td>
          </tr>"
    done < <(printf '%s' "$group" | jq -c '.orders[]')

    sku_rows="${sku_rows}
    <div class=\"sku-group\">
      <div class=\"sku-header\">
        <div class=\"sku-info\">
          <span class=\"sku-code\">${sku}</span>
          <span class=\"sku-name\">${name}</span>
        </div>
        <div class=\"sku-meta\">
          $([ -n "$location" ] && printf '<span class="bin-badge">📦 %s</span>' "$location")
          <span class=\"total-qty\">${total_qty} units total</span>
        </div>
      </div>
      <table class=\"order-table\">
        <thead>
          <tr>
            <th>Order ID</th>
            <th>Channel</th>
            <th>Qty</th>
            <th>Picked ✓</th>
          </tr>
        </thead>
        <tbody>${order_rows}
        </tbody>
      </table>
    </div>"
  done < <(printf '%s' "$sku_groups" | jq -c '.[]')

  # QR code img tag
  local qr_html=""
  if [[ -n "$qr_b64" ]]; then
    qr_html="<img class=\"qr-code\" src=\"data:image/png;base64,${qr_b64}\" alt=\"QR: ${picklist_id}\" />"
  else
    qr_html="<div class=\"qr-placeholder\">${picklist_id}</div>"
  fi

  cat > "$html_file" <<HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<title>Picklist ${picklist_id}</title>
<style>
  @page { size: A4; margin: 12mm 10mm; }
  * { box-sizing: border-box; font-family: Arial, Helvetica, sans-serif; }
  body { font-size: 11px; color: #111; margin: 0; padding: 0; }

  /* ── Header ── */
  .header { display: flex; justify-content: space-between; align-items: flex-start;
            border-bottom: 2px solid #111; padding-bottom: 6px; margin-bottom: 10px; }
  .header-left h1 { font-size: 18px; margin: 0 0 4px; }
  .header-left .meta { font-size: 10px; color: #555; }
  .header-left .meta span { margin-right: 12px; }
  .qr-code { width: 80px; height: 80px; }
  .qr-placeholder { width: 80px; height: 80px; border: 1px solid #ccc;
                    display: flex; align-items: center; justify-content: center;
                    font-size: 8px; text-align: center; color: #666; padding: 4px; }

  /* ── Summary bar ── */
  .summary { background: #f4f4f4; border: 1px solid #ddd; border-radius: 3px;
             padding: 5px 10px; margin-bottom: 12px; font-size: 11px; }
  .summary span { margin-right: 20px; font-weight: bold; }

  /* ── SKU group ── */
  .sku-group { border: 1px solid #ccc; border-radius: 3px; margin-bottom: 10px;
               page-break-inside: avoid; }
  .sku-header { display: flex; justify-content: space-between; align-items: center;
                background: #222; color: #fff; padding: 5px 10px; border-radius: 2px 2px 0 0; }
  .sku-info { display: flex; flex-direction: column; }
  .sku-code { font-size: 13px; font-weight: bold; letter-spacing: 0.5px; }
  .sku-name { font-size: 10px; color: #ccc; margin-top: 1px; }
  .sku-meta { display: flex; align-items: center; gap: 10px; }
  .bin-badge { background: #f39c12; color: #111; font-weight: bold; font-size: 11px;
               padding: 2px 8px; border-radius: 3px; }
  .total-qty { font-size: 12px; font-weight: bold; }

  /* ── Order table ── */
  .order-table { width: 100%; border-collapse: collapse; font-size: 11px; }
  .order-table th { background: #eee; text-align: left; padding: 4px 8px;
                    border-bottom: 1px solid #ccc; font-weight: bold; font-size: 10px;
                    text-transform: uppercase; letter-spacing: 0.4px; }
  .order-table td { padding: 4px 8px; border-bottom: 1px solid #eee; }
  .order-table tr:last-child td { border-bottom: none; }
  .order-table tr:hover { background: #fafafa; }
  .qty { font-weight: bold; text-align: center; }
  .pick-cell { text-align: center; }
  .pick-box { display: inline-block; width: 16px; height: 16px;
              border: 2px solid #333; border-radius: 2px; }

  /* ── Footer ── */
  .footer { margin-top: 14px; border-top: 1px solid #ddd; padding-top: 6px;
            font-size: 9px; color: #999; text-align: center; }

  @media print {
    .sku-group { page-break-inside: avoid; }
  }
</style>
</head>
<body>

<div class="header">
  <div class="header-left">
    <h1>ArryBarry Pick List — ${picklist_id}</h1>
    <div class="meta">
      <span>Generated: ${generated_at}</span>
      <span>Orders: ${order_count}</span>
      <span>SKUs: ${sku_count}</span>
      <span>Scan QR code on return to auto-print labels</span>
    </div>
  </div>
  ${qr_html}
</div>

<div class="summary">
  <span>📦 ${order_count} orders</span>
  <span>🏷️ ${sku_count} SKUs</span>
</div>

${sku_rows}

<div class="footer">
  ArryBarry Warehouse · ${picklist_id} · ${generated_at} · Auto-generated by picklist-ops
</div>

</body>
</html>
HTMLEOF

  log "generate: HTML written to ${html_file}"

  # ── Convert to PDF and print ─────────────────────────────────────────
  _print_picklist_html "$picklist_id" "$html_file"

  # ── Save batch manifest ──────────────────────────────────────────────
  local order_ids
  order_ids=$(printf '%s' "$orders" | jq '[.[].order_id]')
  local manifest
  manifest=$(jq -n \
    --arg id "$picklist_id" \
    --argjson order_ids "$order_ids" \
    --argjson orders "$orders" \
    --arg html "$html_file" \
    --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '{
      picklist_id: $id,
      order_ids: $order_ids,
      order_count: ($order_ids | length),
      status: "printed",
      created_at: $ts,
      html_file: $html
    }')
  _batch_write "$picklist_id" "$manifest"

  log "generate: picklist ${picklist_id} complete"
  return 0
}

# Convert HTML to PDF (via wkhtmltopdf) and send to CUPS printer
_print_picklist_html() {
  local picklist_id="$1" html_file="$2"
  local pdf_file="${html_file%.html}.pdf"

  if command -v wkhtmltopdf &>/dev/null; then
    log "print: converting HTML → PDF (${pdf_file})"
    wkhtmltopdf --quiet --page-size A4 --margin-top 12mm --margin-bottom 12mm \
      --margin-left 10mm --margin-right 10mm \
      "$html_file" "$pdf_file" 2>/dev/null || {
      log "print: wkhtmltopdf failed — falling back to HTML direct print"
      pdf_file="$html_file"
    }
  else
    log "print: wkhtmltopdf not found — sending HTML directly to printer"
    pdf_file="$html_file"
  fi

  if command -v lp &>/dev/null; then
    log "print: sending ${pdf_file} to printer '${PICKLIST_PRINTER}'"
    lp -d "$PICKLIST_PRINTER" "$pdf_file" 2>&1 | \
      while IFS= read -r line; do log "print: lp: ${line}"; done
  else
    log "print: lp not found — picklist saved to ${html_file} (print manually)"
  fi
}

# ══════════════════════════════════════════════════════════════════════
# HELPERS — SHIPPING LABELS
# ══════════════════════════════════════════════════════════════════════

# Print shipping labels for all orders in a batch
_print_shipping_labels() {
  local picklist_id="$1"
  local manifest
  manifest=$(_batch_read "$picklist_id")

  if [[ "$manifest" == "{}" ]]; then
    log "labels: picklist ${picklist_id} not found"
    return 1
  fi

  local order_ids
  order_ids=$(printf '%s' "$manifest" | jq -r '.order_ids[]')
  local count
  count=$(printf '%s' "$manifest" | jq '.order_count')

  log "labels: printing labels for ${count} orders (picklist ${picklist_id})"

  local success=0 failed=0

  while IFS= read -r order_id; do
    [[ -z "$order_id" ]] && continue

    log "labels: fetching label for order ${order_id}"
    local params
    params=$(jq -n --argjson oid "$order_id" '{order_id: $oid}')
    local result
    result=$(bl_request "getOrderLabels" "$params") || {
      log "labels: failed to get label for order ${order_id}"
      failed=$((failed + 1))
      continue
    }

    # BaseLinker returns labels as PDF content (base64 encoded) or a URL
    local label_url label_b64
    label_url=$(printf '%s' "$result" | jq -r '.label_content_url // empty')
    label_b64=$(printf '%s' "$result" | jq -r '.label // empty')

    local label_file="/tmp/label-${picklist_id}-${order_id}.pdf"

    if [[ -n "$label_url" ]]; then
      curl -sS -o "$label_file" "$label_url" || {
        log "labels: download failed for order ${order_id}"
        failed=$((failed + 1))
        continue
      }
    elif [[ -n "$label_b64" ]]; then
      printf '%s' "$label_b64" | base64 -d > "$label_file" || {
        log "labels: base64 decode failed for order ${order_id}"
        failed=$((failed + 1))
        continue
      }
    else
      log "labels: no label data for order ${order_id} (may not have shipment created)"
      failed=$((failed + 1))
      continue
    fi

    # Print the label
    if command -v lp &>/dev/null; then
      lp -d "$SHIPPING_LABEL_PRINTER" "$label_file" 2>&1 | \
        while IFS= read -r line; do log "labels: lp: ${line}"; done
      success=$((success + 1))
    else
      log "labels: lp not found — label saved to ${label_file}"
      success=$((success + 1))
    fi

    # Mark order as picked if status configured
    if [[ -n "$PICKLIST_PICKED_STATUS_ID" ]]; then
      local sp
      sp=$(jq -n --argjson oid "$order_id" --argjson sid "$PICKLIST_PICKED_STATUS_ID" \
        '{order_id: $oid, status_id: $sid}')
      bl_request "setOrderStatus" "$sp" > /dev/null 2>&1 || \
        log "labels: failed to mark order ${order_id} as picked"
    fi

    rm -f "$label_file"
  done <<< "$order_ids"

  log "labels: done — ${success} printed, ${failed} failed"

  # Update batch manifest with return timestamp
  local updated
  updated=$(printf '%s' "$manifest" | jq \
    --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '.status = "returned" | .returned_at = $ts')
  _batch_write "$picklist_id" "$updated"

  return 0
}

# ══════════════════════════════════════════════════════════════════════
# SUBCOMMAND — OVERNIGHT
# ══════════════════════════════════════════════════════════════════════

cmd_overnight() {
  log "=== picklist-ops: overnight batch ==="

  # Reset fetch pointer to catch everything since last close (~16h ago)
  local cutoff
  cutoff=$(( $(date +%s) - 57600 ))  # 16 hours
  local last_fetch
  last_fetch=$(_last_fetch_read)
  # Only reset if last fetch was more recent than the cutoff (i.e. we already fetched today)
  if (( last_fetch > cutoff )); then
    log "overnight: resetting fetch pointer to 16h ago"
    _last_fetch_write "$cutoff"
  fi

  _fetch_new_orders

  local queued
  queued=$(_queue_read)
  local total
  total=$(printf '%s' "$queued" | jq 'length')

  if (( total == 0 )); then
    log "overnight: no orders in queue — nothing to print"
    return 0
  fi

  log "overnight: ${total} orders to batch (no size cap)"

  # For overnight: group ALL orders into SKU-optimised batches.
  # No hard cap — but we split into physically manageable chunks if needed
  # (configurable: if a single SKU has >200 orders, still print all together).
  local picklist_id
  picklist_id=$(_next_picklist_id)

  _generate_and_print_picklist "$picklist_id" "$queued"

  # Clear the queue
  local all_ids
  all_ids=$(printf '%s' "$queued" | jq '[.[].order_id]')
  _queue_remove "$all_ids"
  _batch_timer_clear

  log "overnight: batch ${picklist_id} printed (${total} orders)"
  log "=== picklist-ops: overnight complete ==="
}

# ══════════════════════════════════════════════════════════════════════
# SUBCOMMAND — DAYTIME
# ══════════════════════════════════════════════════════════════════════

cmd_daytime() {
  log "=== picklist-ops: daytime batch check ==="

  # Fetch any new orders since last run
  _fetch_new_orders

  local queued
  queued=$(_queue_read)
  local total
  total=$(printf '%s' "$queued" | jq 'length')

  if (( total == 0 )); then
    log "daytime: queue empty"
    _batch_timer_clear
    return 0
  fi

  # Start timer if this is the first orders in a new batch window
  local timer_start
  timer_start=$(_batch_timer_read)
  local now
  now=$(date +%s)

  if [[ "$timer_start" == "0" ]]; then
    _batch_timer_write
    timer_start="$now"
    log "daytime: batch timer started (${total} orders, waiting for ${PICKLIST_BATCH_SIZE})"
  fi

  local elapsed_mins
  elapsed_mins=$(( (now - timer_start) / 60 ))
  log "daytime: ${total} orders queued, ${elapsed_mins}m elapsed (timeout: ${PICKLIST_BATCH_TIMEOUT_MINS}m)"

  # Decide whether to print now
  local should_print=0
  if (( total >= PICKLIST_BATCH_SIZE )); then
    log "daytime: batch size reached (${total} >= ${PICKLIST_BATCH_SIZE})"
    should_print=1
  elif (( elapsed_mins >= PICKLIST_BATCH_TIMEOUT_MINS )); then
    log "daytime: time limit reached (${elapsed_mins}m >= ${PICKLIST_BATCH_TIMEOUT_MINS}m) — printing partial batch"
    should_print=1
  fi

  if (( should_print == 0 )); then
    log "daytime: not yet ready to print (${total}/${PICKLIST_BATCH_SIZE} orders, ${elapsed_mins}/${PICKLIST_BATCH_TIMEOUT_MINS}m)"
    return 0
  fi

  # Take up to PICKLIST_BATCH_SIZE orders (oldest first — jq array order preserved from getOrders)
  local batch
  batch=$(printf '%s' "$queued" | jq --argjson n "$PICKLIST_BATCH_SIZE" '.[0:$n]')
  local batch_count
  batch_count=$(printf '%s' "$batch" | jq 'length')

  local picklist_id
  picklist_id=$(_next_picklist_id)

  _generate_and_print_picklist "$picklist_id" "$batch"

  local batch_ids
  batch_ids=$(printf '%s' "$batch" | jq '[.[].order_id]')
  _queue_remove "$batch_ids"
  _batch_timer_clear

  # If there are more orders, restart the timer
  local remaining
  remaining=$(_queue_read)
  local remaining_count
  remaining_count=$(printf '%s' "$remaining" | jq 'length')
  if (( remaining_count > 0 )); then
    _batch_timer_write
    log "daytime: ${remaining_count} orders remain in queue — timer restarted"
  fi

  log "daytime: batch ${picklist_id} printed (${batch_count} orders)"
  log "=== picklist-ops: daytime check complete ==="
}

# ══════════════════════════════════════════════════════════════════════
# SUBCOMMAND — PRINT NEXT 25
# ══════════════════════════════════════════════════════════════════════

cmd_print_next_25() {
  local count="${1:-$PICKLIST_BATCH_SIZE}"
  log "=== picklist-ops: manual print-next-${count} ==="

  # Fetch any new orders first
  _fetch_new_orders

  local queued
  queued=$(_queue_read)
  local total
  total=$(printf '%s' "$queued" | jq 'length')

  if (( total == 0 )); then
    log "manual: queue is empty — nothing to print"
    return 0
  fi

  local batch
  batch=$(printf '%s' "$queued" | jq --argjson n "$count" '.[0:$n]')
  local batch_count
  batch_count=$(printf '%s' "$batch" | jq 'length')

  local picklist_id
  picklist_id=$(_next_picklist_id)
  _generate_and_print_picklist "$picklist_id" "$batch"

  local batch_ids
  batch_ids=$(printf '%s' "$batch" | jq '[.[].order_id]')
  _queue_remove "$batch_ids"
  _batch_timer_clear

  log "manual: batch ${picklist_id} printed (${batch_count} of ${total} orders)"
  log "=== picklist-ops: manual print-next done ==="
}

# ══════════════════════════════════════════════════════════════════════
# SUBCOMMAND — PRINT SELECTED ORDERS
# ══════════════════════════════════════════════════════════════════════

cmd_print_selected() {
  local selected_ids=("$@")
  local id_count="${#selected_ids[@]}"

  if (( id_count == 0 )); then
    log "error: print-selected requires at least one order ID"
    exit 1
  fi

  log "=== picklist-ops: manual print-selected (${id_count} order IDs) ==="

  # Build JSON array of selected IDs for the API call
  local ids_json
  ids_json=$(printf '%s\n' "${selected_ids[@]}" | jq -R . | jq -s .)

  # Fetch the specific orders directly from BaseLinker (bypass queue)
  local orders="[]"
  for order_id in "${selected_ids[@]}"; do
    local params
    params=$(jq -n --argjson oid "$order_id" '{order_id: $oid}')
    local result
    result=$(bl_request "getOrders" "$params") || {
      log "selected: failed to fetch order ${order_id}"
      continue
    }
    local order_arr
    order_arr=$(printf '%s' "$result" | jq '.orders // []')
    orders=$(printf '%s\n%s' "$orders" "$order_arr" | jq -s 'add | unique_by(.order_id)')
  done

  local found
  found=$(printf '%s' "$orders" | jq 'length')
  log "selected: fetched ${found} of ${id_count} requested orders"

  if (( found == 0 )); then
    log "selected: no orders found — aborting"
    exit 1
  fi

  local picklist_id
  picklist_id=$(_next_picklist_id)
  _generate_and_print_picklist "$picklist_id" "$orders"

  # Remove these from the queue if they were queued
  local fetched_ids
  fetched_ids=$(printf '%s' "$orders" | jq '[.[].order_id]')
  _queue_remove "$fetched_ids"

  log "selected: batch ${picklist_id} printed (${found} orders)"
  log "=== picklist-ops: manual print-selected done ==="
}

# ══════════════════════════════════════════════════════════════════════
# SUBCOMMAND — SCAN ON RETURN
# ══════════════════════════════════════════════════════════════════════

cmd_scan_return() {
  local picklist_id="$1"

  if [[ -z "$picklist_id" ]]; then
    log "error: scan-return requires a picklist ID (e.g. PL-20260705-001)"
    exit 1
  fi

  log "=== picklist-ops: scan-return ${picklist_id} ==="
  _print_shipping_labels "$picklist_id"
  log "=== picklist-ops: scan-return complete ==="
}

# ══════════════════════════════════════════════════════════════════════
# MAIN DISPATCH
# ══════════════════════════════════════════════════════════════════════

CMD="${1:-}"
shift || true

case "$CMD" in
  overnight)
    cmd_overnight
    ;;
  daytime)
    cmd_daytime
    ;;
  print-next-25)
    cmd_print_next_25 "${1:-}"
    ;;
  print-selected)
    if [[ $# -eq 0 ]]; then
      log "error: print-selected requires order IDs as arguments"
      exit 1
    fi
    cmd_print_selected "$@"
    ;;
  scan-return)
    cmd_scan_return "${1:-}"
    ;;
  *)
    cat >&2 <<USAGE
Usage: $(basename "$0") <command> [args]

Commands:
  overnight                  Print all queued orders (pre-open batch, no size cap)
  daytime                    Check queue and print if batch size or time limit reached
  print-next-25 [count]      Manually print next N orders (default: ${PICKLIST_BATCH_SIZE})
  print-selected <id> [id…]  Manually print specific order IDs
  scan-return <picklist_id>  Print shipping labels for a returned picklist

Environment (via Doppler):
  PICKLIST_ORDER_STATUS_ID   BaseLinker status ID for orders ready to pick
  PICKLIST_MARKED_STATUS_ID  Status set when order is added to a picklist
  PICKLIST_PICKED_STATUS_ID  Status set when order is confirmed picked
  PICKLIST_PRINTER           CUPS printer name for picklists (default: picklist)
  SHIPPING_LABEL_PRINTER     CUPS printer name for labels (default: label)
  PICKLIST_BATCH_SIZE        Daytime batch size (default: 25)
  PICKLIST_BATCH_TIMEOUT_MINS  Time fallback in minutes (default: 30)
  WAREHOUSE_OPEN_HOUR        Hour warehouse opens (default: 8)
  PICKLIST_LOCATION_FIELD    BaseLinker field name for bin location (default: location)
  PICKLIST_OUTPUT_DIR        Output directory for HTML/PDF files
USAGE
    exit 1
    ;;
esac
