#!/usr/bin/env bash
set -euo pipefail

# picklist-ops/run.sh — Picklist automation for ArryBarry warehouse
#
# Modes:
#   --auto              Monitor queue; print if 25+ orders OR oldest > 60 min
#   --morning-batch     Print ALL overnight ready orders (no 25-order cap)
#   --print-next-25     Manually print the next 25 from the queue
#   --print-selected IDS  Print specific order IDs (comma-separated)
#   --print-label ID    Print shipping label for one order (QR scan trigger)
#
# Env (Doppler shared-services):
#   BASELINKER_API_TOKEN      BaseLinker API token
#   OBSIDIAN_API_KEY          Obsidian REST API key
#   OBSIDIAN_HOST             Obsidian REST API host URL
#   PICKLIST_READY_STATUS_ID  BaseLinker status_id for "Ready to Ship"
#   PICKLIST_WEBHOOK_HOST     thepopebot host URL for QR codes
#   PICKLIST_LABEL_PRINTER    BaseLinker printer ID (default: 0)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../marketplace-lib" && pwd)"

source "${LIB_DIR}/config.sh"
source "${LIB_DIR}/cache.sh"
source "${LIB_DIR}/baselinker.sh"
source "${LIB_DIR}/alerts.sh"

# ── Constants ─────────────────────────────────────────────────────────────────
STATE_DIR="${STATE_BASE}/picklist-ops"
QUEUE_FILE="${STATE_DIR}/queue.json"
BATCH_COUNTER_FILE="${STATE_DIR}/batch-counter.txt"
LAST_BATCH_FILE="${STATE_DIR}/last-batch.json"
LOCK_FILE="/tmp/picklist-ops.lock"

AUTO_BATCH_SIZE=25          # orders per auto/manual batch
AUTO_TIMEOUT_SECS=3600      # 60 minutes before forcing a partial batch
MORNING_BATCH_HOUR=8        # hour (local) treated as the morning batch window

READY_STATUS_ID="${PICKLIST_READY_STATUS_ID:-}"
WEBHOOK_HOST="${PICKLIST_WEBHOOK_HOST:-}"
LABEL_PRINTER="${PICKLIST_LABEL_PRINTER:-0}"

mkdir -p "$STATE_DIR"

# ── Helpers ───────────────────────────────────────────────────────────────────

_require_env() {
  local missing=()
  [[ -z "$BASELINKER_API_TOKEN" ]] && missing+=("BASELINKER_API_TOKEN")
  [[ -z "$OBSIDIAN_API_KEY" ]]      && missing+=("OBSIDIAN_API_KEY")
  [[ -z "$OBSIDIAN_HOST" ]]         && missing+=("OBSIDIAN_HOST")
  [[ -z "$READY_STATUS_ID" ]]       && missing+=("PICKLIST_READY_STATUS_ID")
  if [[ ${#missing[@]} -gt 0 ]]; then
    log "picklist-ops: missing env vars: ${missing[*]}"
    exit 1
  fi
}

_next_batch_number() {
  local n=1
  if [[ -f "$BATCH_COUNTER_FILE" ]]; then
    n=$(cat "$BATCH_COUNTER_FILE" 2>/dev/null || echo 0)
    n=$(( n + 1 ))
  fi
  printf '%d' "$n" > "$BATCH_COUNTER_FILE"
  echo "$n"
}

_queue_read() {
  if [[ -f "$QUEUE_FILE" ]]; then
    cat "$QUEUE_FILE"
  else
    echo "[]"
  fi
}

_queue_write() {
  local data="$1"
  printf '%s' "$data" > "$QUEUE_FILE"
}

_queue_remove_ids() {
  local queue="$1"
  local ids_json="$2"  # JSON array of order_ids to remove
  printf '%s' "$queue" | jq \
    --argjson ids "$ids_json" \
    '[.[] | select(.order_id as $id | $ids | index($id) == null)]'
}

# ── Fetch ready orders from BaseLinker ───────────────────────────────────────
# Returns JSON array of order objects
_fetch_ready_orders() {
  local since="${1:-0}"
  local params
  params=$(jq -n \
    --argjson since "$since" \
    --argjson sid "$READY_STATUS_ID" \
    '{date_from: $since, status_id: $sid, get_unconfirmed_orders: false}')

  local raw
  raw=$(bl_request "getOrders" "$params") || { log "picklist-ops: getOrders failed"; echo "[]"; return 1; }

  local orders
  orders=$(printf '%s' "$raw" | jq -c '.orders // []')
  log "picklist-ops: fetched $(printf '%s' "$orders" | jq 'length') ready orders since ${since}"
  printf '%s' "$orders"
}

# ── Update the queue with currently-ready orders ──────────────────────────────
# Adds new orders, does NOT remove orders that left ready status (they'll be
# cleared after batching).
_update_queue() {
  local fresh_orders="$1"
  local now
  now=$(date +%s)
  local existing
  existing=$(_queue_read)

  local existing_ids
  existing_ids=$(printf '%s' "$existing" | jq '[.[].order_id]')

  local new_orders
  new_orders=$(printf '%s' "$fresh_orders" | jq \
    --argjson existing_ids "$existing_ids" \
    --argjson now "$now" \
    '[.[] | select(.order_id as $id | $existing_ids | index($id) == null)
         | {order_id: .order_id,
            customer_name: ((.delivery_fullname // .customer_login // "Unknown") | .[0:40]),
            products: [.products // [] | .[] | {
              sku: (.sku // .product_id // "NO-SKU"),
              name: (.name // "Unknown product" | .[0:60]),
              quantity: (.quantity // 1 | tonumber)
            }],
            added_at: $now}]')

  local new_count
  new_count=$(printf '%s' "$new_orders" | jq 'length')

  local merged
  if (( new_count > 0 )); then
    merged=$(printf '%s\n%s' "$existing" "$new_orders" | jq -s 'add | sort_by(.added_at)')
    _queue_write "$merged"
    log "picklist-ops: queue updated — added ${new_count} new orders"
  else
    log "picklist-ops: queue unchanged ($(printf '%s' "$existing" | jq 'length') orders)"
    merged="$existing"
  fi

  printf '%s' "$merged"
}

# ── Generate SKU-grouped HTML picklist ────────────────────────────────────────
_generate_html() {
  local orders_json="$1"
  local batch_num="$2"
  local batch_label="${3:-Batch #${batch_num}}"
  local date_str
  date_str=$(date '+%Y-%m-%d %H:%M')

  local order_count
  order_count=$(printf '%s' "$orders_json" | jq 'length')

  # Build SKU-grouped data: { "SKU": { name, rows: [{order_id, customer, qty}] } }
  local sku_data
  sku_data=$(printf '%s' "$orders_json" | jq '
    reduce .[] as $order (
      {};
      reduce ($order.products // [])[] as $prod (
        .;
        .[$prod.sku // "NO-SKU"] += {
          name: ($prod.name // "Unknown"),
          sku: ($prod.sku // "NO-SKU"),
          rows: ((.[$prod.sku // "NO-SKU"].rows // []) + [{
            order_id: $order.order_id,
            customer: $order.customer_name,
            quantity: ($prod.quantity // 1 | tonumber)
          }])
        }
      )
    )
    | to_entries
    | sort_by(.key)
    | from_entries
  ')

  local webhook_host="${WEBHOOK_HOST:-}"
  local qr_base=""
  if [[ -n "$webhook_host" ]]; then
    qr_base="${webhook_host}/webhook/picklist-label?order_id="
  fi

  # Build SKU section HTML
  local sku_sections=""
  while IFS= read -r sku_entry; do
    local sku sku_name total_units total_orders rows_html
    sku=$(printf '%s' "$sku_entry" | jq -r '.key')
    sku_name=$(printf '%s' "$sku_entry" | jq -r '.value.name')
    total_units=$(printf '%s' "$sku_entry" | jq '[.value.rows[].quantity] | add // 0')
    total_orders=$(printf '%s' "$sku_entry" | jq '.value.rows | length')

    rows_html=""
    while IFS= read -r row; do
      local order_id customer qty qr_img_html
      order_id=$(printf '%s' "$row" | jq -r '.order_id')
      customer=$(printf '%s' "$row" | jq -r '.customer' | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
      qty=$(printf '%s' "$row" | jq -r '.quantity')

      if [[ -n "$qr_base" ]]; then
        local qr_url
        qr_url="https://api.qrserver.com/v1/create-qr-code/?size=80x80&ecc=M&data=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${qr_base}${order_id}'))" 2>/dev/null || printf '%s%s' "$qr_base" "$order_id")"
        qr_img_html="<img class=\"qr\" src=\"${qr_url}\" alt=\"Scan to print label\" />"
      else
        qr_img_html="<span class=\"qr-placeholder\">Order<br>${order_id}</span>"
      fi

      rows_html+="<tr>
        <td class=\"order-id\">${order_id}</td>
        <td class=\"customer\">${customer}</td>
        <td class=\"qty\">${qty}</td>
        <td class=\"qr-cell\">${qr_img_html}</td>
      </tr>"
    done < <(printf '%s' "$sku_entry" | jq -c '.value.rows[]')

    sku_sections+="<div class=\"sku-block\">
      <div class=\"sku-header\">
        <span class=\"sku-code\">${sku}</span>
        <span class=\"sku-name\">${sku_name}</span>
        <span class=\"sku-totals\">${total_units} units &bull; ${total_orders} orders</span>
      </div>
      <table class=\"order-table\">
        <thead><tr>
          <th>Order ID</th><th>Customer</th><th>Qty</th><th>Label</th>
        </tr></thead>
        <tbody>${rows_html}</tbody>
      </table>
    </div>"
  done < <(printf '%s' "$sku_data" | jq -c 'to_entries[]')

  cat <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>ArryBarry Pick List — ${batch_label}</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: Arial, sans-serif; font-size: 11pt; color: #111; background: #fff; }

    /* ── Header ── */
    .page-header { border-bottom: 3px solid #222; padding: 8px 0 6px; margin-bottom: 16px; }
    .page-header h1 { font-size: 16pt; letter-spacing: 0.03em; }
    .page-header .meta { font-size: 9pt; color: #555; margin-top: 2px; }

    /* ── SKU block ── */
    .sku-block { margin-bottom: 18px; break-inside: avoid; }
    .sku-header {
      background: #222; color: #fff; padding: 4px 8px;
      display: flex; align-items: baseline; gap: 10px;
    }
    .sku-code { font-weight: bold; font-size: 11pt; font-family: monospace; }
    .sku-name { flex: 1; font-size: 10pt; opacity: 0.85; }
    .sku-totals { font-size: 9pt; opacity: 0.75; white-space: nowrap; }

    /* ── Order table ── */
    .order-table { width: 100%; border-collapse: collapse; }
    .order-table th {
      background: #f0f0f0; text-align: left; padding: 3px 6px;
      font-size: 9pt; border-bottom: 1px solid #ccc;
    }
    .order-table td { padding: 4px 6px; border-bottom: 1px solid #eee; vertical-align: middle; }
    .order-table tr:last-child td { border-bottom: none; }
    .order-id { font-family: monospace; font-size: 10pt; width: 90px; }
    .customer { font-size: 10pt; }
    .qty { text-align: center; font-weight: bold; font-size: 12pt; width: 40px; }
    .qr-cell { text-align: center; width: 90px; padding: 2px; }
    .qr { width: 72px; height: 72px; display: block; margin: auto; }
    .qr-placeholder {
      display: inline-block; width: 72px; height: 72px; line-height: 1.3;
      border: 1px dashed #999; font-size: 8pt; text-align: center;
      color: #666; padding: 8px 2px;
    }

    /* ── Print controls (screen only) ── */
    .print-bar {
      position: fixed; top: 0; right: 0;
      background: #0066cc; color: #fff;
      padding: 8px 16px; font-size: 10pt; cursor: pointer;
      border-radius: 0 0 0 6px; z-index: 100;
    }
    .print-bar:hover { background: #004a99; }

    /* ── Print ── */
    @media print {
      .print-bar { display: none; }
      body { font-size: 10pt; }
      .sku-block { break-inside: avoid; }
      .order-table td, .order-table th { padding: 2px 5px; }
      .qr { width: 60px; height: 60px; }
    }
  </style>
</head>
<body>

<button class="print-bar" onclick="window.print()">&#128438; Print</button>

<div class="page-header">
  <h1>ARRYBARRY PICK LIST &mdash; ${batch_label}</h1>
  <div class="meta">${date_str} &bull; ${order_count} orders &bull; Printed by Bigman Engine</div>
</div>

${sku_sections}

</body>
</html>
HTML
}

# ── Write picklist to Obsidian vault ─────────────────────────────────────────
_save_picklist() {
  local html="$1"
  local batch_num="$2"
  local ts
  ts=$(date -u '+%Y%m%d-%H%M%S')
  local vault_path="08-Operations/Picklists/${ts}-batch-${batch_num}.html"

  local http_code
  http_code=$(curl -sS -o /dev/null -w '%{http_code}' \
    -X PUT "${VAULT_URL}/vault/${vault_path}" \
    -H "Authorization: Bearer ${OBSIDIAN_API_KEY}" \
    -H "Content-Type: text/html" \
    --data-binary "$html")

  if [[ "$http_code" == "204" || "$http_code" == "200" ]]; then
    log "picklist-ops: saved picklist to vault: ${vault_path}"
  else
    log "picklist-ops: vault write failed (HTTP ${http_code}) — saving to /tmp"
    printf '%s' "$html" > "/tmp/picklist-${ts}-batch-${batch_num}.html"
    log "picklist-ops: fallback output: /tmp/picklist-${ts}-batch-${batch_num}.html"
  fi

  # Record last batch metadata
  printf '%s' "$(jq -n \
    --arg ts "$ts" \
    --argjson batch "$batch_num" \
    --arg path "$vault_path" \
    '{ts: $ts, batch: $batch, path: $path, epoch: now | floor}')" \
    > "$LAST_BATCH_FILE"
}

# ── Execute a batch of orders ─────────────────────────────────────────────────
_run_batch() {
  local orders_json="$1"
  local batch_label="${2:-}"
  local count
  count=$(printf '%s' "$orders_json" | jq 'length')

  if (( count == 0 )); then
    log "picklist-ops: batch called with 0 orders — skipping"
    return 0
  fi

  local batch_num
  batch_num=$(_next_batch_number)
  [[ -z "$batch_label" ]] && batch_label="Batch #${batch_num}"
  log "picklist-ops: generating ${batch_label} (${count} orders)"

  local html
  html=$(_generate_html "$orders_json" "$batch_num" "$batch_label")
  _save_picklist "$html" "$batch_num"

  # Remove batched orders from the queue
  local batched_ids
  batched_ids=$(printf '%s' "$orders_json" | jq '[.[].order_id]')
  local queue
  queue=$(_queue_read)
  local remaining
  remaining=$(_queue_remove_ids "$queue" "$batched_ids")
  _queue_write "$remaining"

  local remaining_count
  remaining_count=$(printf '%s' "$remaining" | jq 'length')
  log "picklist-ops: ${batch_label} done — ${remaining_count} orders remain in queue"
}

# ══════════════════════════════════════════════════════════════════════════════
# MODE: --auto
# Fetch ready orders, update queue, trigger batch if 25+ or 60-min timeout.
# ══════════════════════════════════════════════════════════════════════════════
mode_auto() {
  # Use last-batch epoch as 'since', or last 24h as a safety window
  local since
  if [[ -f "$LAST_BATCH_FILE" ]]; then
    since=$(jq -r '.epoch // 0' "$LAST_BATCH_FILE" 2>/dev/null || echo 0)
  else
    since=$(( $(date +%s) - 86400 ))
  fi

  local fresh_orders
  fresh_orders=$(_fetch_ready_orders "$since") || { log "picklist-ops: fetch failed, aborting auto"; return 1; }

  local queue
  queue=$(_update_queue "$fresh_orders")

  local queue_count
  queue_count=$(printf '%s' "$queue" | jq 'length')
  log "picklist-ops: auto — queue has ${queue_count} orders"

  if (( queue_count == 0 )); then
    return 0
  fi

  # Check 25-order threshold
  local should_batch=false

  if (( queue_count >= AUTO_BATCH_SIZE )); then
    log "picklist-ops: auto — threshold met (${queue_count} >= ${AUTO_BATCH_SIZE})"
    should_batch=true
  fi

  # Check timeout on oldest queued order
  if [[ "$should_batch" == "false" ]]; then
    local oldest_ts
    oldest_ts=$(printf '%s' "$queue" | jq '.[0].added_at // 0')
    local now
    now=$(date +%s)
    local age=$(( now - oldest_ts ))
    if (( age >= AUTO_TIMEOUT_SECS )); then
      log "picklist-ops: auto — timeout triggered (oldest order is ${age}s old >= ${AUTO_TIMEOUT_SECS}s)"
      should_batch=true
    else
      local remaining=$(( AUTO_TIMEOUT_SECS - age ))
      log "picklist-ops: auto — waiting (${queue_count} orders, ${remaining}s before timeout)"
    fi
  fi

  if [[ "$should_batch" == "true" ]]; then
    local batch_orders
    batch_orders=$(printf '%s' "$queue" | jq --argjson n "$AUTO_BATCH_SIZE" '.[0:$n]')
    _run_batch "$batch_orders"
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# MODE: --morning-batch
# Fetch ALL overnight ready orders, no 25-order cap. Grouped by SKU.
# ══════════════════════════════════════════════════════════════════════════════
mode_morning_batch() {
  # "Overnight" = since yesterday at the morning batch hour
  local now
  now=$(date +%s)
  local yesterday_morning
  yesterday_morning=$(date -d "yesterday ${MORNING_BATCH_HOUR}:00" +%s 2>/dev/null || \
                      date -v-1d -v${MORNING_BATCH_HOUR}H -v0M -v0S +%s 2>/dev/null || \
                      echo $(( now - 24 * 3600 )))

  log "picklist-ops: morning-batch — fetching all ready orders since ${yesterday_morning}"

  local orders
  orders=$(_fetch_ready_orders "$yesterday_morning") || { log "picklist-ops: fetch failed"; return 1; }

  local count
  count=$(printf '%s' "$orders" | jq 'length')
  log "picklist-ops: morning-batch — ${count} orders found"

  if (( count == 0 )); then
    log "picklist-ops: morning-batch — no orders to pick, skipping"
    return 0
  fi

  # Merge these orders into queue state (they may already be partially there)
  _update_queue "$orders" > /dev/null

  _run_batch "$orders" "Morning Batch $(date '+%d %b')"
}

# ══════════════════════════════════════════════════════════════════════════════
# MODE: --print-next-25
# Manual trigger: take next 25 from the queue and generate a picklist.
# ══════════════════════════════════════════════════════════════════════════════
mode_print_next_25() {
  # Refresh queue first
  local since
  if [[ -f "$LAST_BATCH_FILE" ]]; then
    since=$(jq -r '.epoch // 0' "$LAST_BATCH_FILE" 2>/dev/null || echo 0)
  else
    since=$(( $(date +%s) - 86400 ))
  fi

  local fresh_orders
  fresh_orders=$(_fetch_ready_orders "$since") || fresh_orders="[]"
  _update_queue "$fresh_orders" > /dev/null

  local queue
  queue=$(_queue_read)
  local queue_count
  queue_count=$(printf '%s' "$queue" | jq 'length')

  if (( queue_count == 0 )); then
    log "picklist-ops: print-next-25 — queue is empty, nothing to print"
    return 0
  fi

  local batch_orders
  batch_orders=$(printf '%s' "$queue" | jq --argjson n "$AUTO_BATCH_SIZE" '.[0:$n]')
  _run_batch "$batch_orders" "Manual Next 25"
}

# ══════════════════════════════════════════════════════════════════════════════
# MODE: --print-selected ORDER_IDS
# Manual trigger for specific order IDs (comma-separated).
# ══════════════════════════════════════════════════════════════════════════════
mode_print_selected() {
  local raw_ids="$1"
  if [[ -z "$raw_ids" ]]; then
    log "picklist-ops: print-selected — no order IDs provided"
    exit 1
  fi

  # Parse comma-separated IDs into a JSON array
  local ids_json
  ids_json=$(printf '%s' "$raw_ids" | tr ',' '\n' | tr -d ' ' | grep -E '^[0-9]+$' | jq -R . | jq -s '.')

  local id_count
  id_count=$(printf '%s' "$ids_json" | jq 'length')
  log "picklist-ops: print-selected — fetching ${id_count} specific orders"

  # Fetch each order individually (BaseLinker doesn't support multi-ID filter natively)
  local orders_json="[]"
  while IFS= read -r order_id; do
    order_id=$(printf '%s' "$order_id" | tr -d '"')
    local params
    params=$(jq -n --argjson id "$order_id" '{order_id: $id}')
    local result
    result=$(bl_request "getOrders" "$params") || { log "picklist-ops: failed to fetch order ${order_id}"; continue; }
    local order
    order=$(printf '%s' "$result" | jq -c '.orders // [] | .[0]? // empty')
    if [[ -n "$order" ]]; then
      orders_json=$(printf '%s\n[%s]' "$orders_json" "$order" | jq -s 'add')
    fi
  done < <(printf '%s' "$ids_json" | jq -c '.[]')

  local count
  count=$(printf '%s' "$orders_json" | jq 'length')
  log "picklist-ops: print-selected — ${count} orders resolved"

  if (( count == 0 )); then
    log "picklist-ops: print-selected — no valid orders found"
    return 0
  fi

  # Transform to queue format with current timestamp
  local now
  now=$(date +%s)
  local queue_format
  queue_format=$(printf '%s' "$orders_json" | jq \
    --argjson now "$now" \
    '[.[] | {
      order_id: .order_id,
      customer_name: ((.delivery_fullname // .customer_login // "Unknown") | .[0:40]),
      products: [.products // [] | .[] | {
        sku: (.sku // .product_id // "NO-SKU"),
        name: (.name // "Unknown product" | .[0:60]),
        quantity: (.quantity // 1 | tonumber)
      }],
      added_at: $now
    }]')

  _run_batch "$queue_format" "Manual Selected (${count} orders)"
}

# ══════════════════════════════════════════════════════════════════════════════
# MODE: --print-label ORDER_ID
# QR scan trigger at pack station — print shipping label via BaseLinker.
# ══════════════════════════════════════════════════════════════════════════════
mode_print_label() {
  local order_id="$1"
  if [[ -z "$order_id" || ! "$order_id" =~ ^[0-9]+$ ]]; then
    log "picklist-ops: print-label — invalid order_id: '${order_id}'"
    exit 1
  fi

  log "picklist-ops: print-label — order ${order_id}, printer ${LABEL_PRINTER}"

  # Try printOrderCourierLabel first (sends to connected BaseLinker printer)
  local params
  params=$(jq -n \
    --argjson oid "$order_id" \
    --argjson printer "$LABEL_PRINTER" \
    '{order_id: $oid, printer_type: $printer}')

  local result
  result=$(bl_request "printOrderCourierLabel" "$params") || {
    log "picklist-ops: printOrderCourierLabel failed for order ${order_id}"
    # Fallback: get label URL and log it for manual retrieval
    local label_params
    label_params=$(jq -n --argjson oid "$order_id" '{order_id: $oid}')
    local label_data
    label_data=$(bl_request "getOrderCourierLabel" "$label_params") || {
      log "picklist-ops: getOrderCourierLabel also failed — check printer config in BaseLinker"
      return 1
    }
    local label_url
    label_url=$(printf '%s' "$label_data" | jq -r '.label_path // .url // empty')
    if [[ -n "$label_url" ]]; then
      log "picklist-ops: label URL (print manually): ${label_url}"
    fi
    return 0
  }

  log "picklist-ops: print-label — label sent to printer for order ${order_id}"
}

# ══════════════════════════════════════════════════════════════════════════════
# Entry point
# ══════════════════════════════════════════════════════════════════════════════
main() {
  local mode="${1:-}"

  case "$mode" in
    --auto)
      _require_env
      exec 200>"$LOCK_FILE"
      flock -n 200 || { log "picklist-ops: another instance running"; exit 0; }
      mode_auto
      ;;
    --morning-batch)
      _require_env
      exec 200>"$LOCK_FILE"
      flock -n 200 || { log "picklist-ops: another instance running"; exit 0; }
      mode_morning_batch
      ;;
    --print-next-25)
      _require_env
      mode_print_next_25
      ;;
    --print-selected)
      _require_env
      mode_print_selected "${2:-}"
      ;;
    --print-label)
      _require_env
      mode_print_label "${2:-}"
      ;;
    *)
      printf 'Usage: %s --auto | --morning-batch | --print-next-25 | --print-selected IDS | --print-label ORDER_ID\n' "$0" >&2
      exit 1
      ;;
  esac
}

main "$@"
