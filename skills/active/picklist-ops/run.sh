#!/usr/bin/env bash
set -euo pipefail

# picklist-ops/run.sh — Warehouse picklist automation for ArryBarry
#
# Modes:
#   --mode=auto     (default) check order threshold + time-limit fallback
#   --mode=morning  all overnight orders, no size cap
#   --mode=manual   specific order IDs or next N orders (web UI)
#
# Runs as:
#   doppler run -p shared-services -c prd -- bash ../skills/active/picklist-ops/run.sh [args]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../marketplace-lib" && pwd)"

source "${LIB_DIR}/config.sh"
source "${LIB_DIR}/baselinker.sh"
source "${LIB_DIR}/alerts.sh"

# ── Picklist settings (overridable via env) ────────────────────────────
BATCH_SIZE="${PICKLIST_BATCH_SIZE:-25}"
TIME_LIMIT_HOURS="${PICKLIST_TIME_LIMIT_HOURS:-1}"
READY_STATUS_ID="${BL_PICKLIST_STATUS_ID:-}"

# ── State & batch directories ──────────────────────────────────────────
# Use /app/data/ so state survives container restarts (data/ is volume-mounted)
PICKLIST_DATA_DIR="/app/data/picklist-ops"
BATCHES_DIR="${PICKLIST_DATA_DIR}/batches"
STATE_FILE="${PICKLIST_DATA_DIR}/state.json"
mkdir -p "$BATCHES_DIR"

# ── Argument parsing ───────────────────────────────────────────────────
MODE="auto"
ORDER_IDS_ARG=""
LIMIT_ARG=""

for arg in "$@"; do
  case "$arg" in
    --mode=*)      MODE="${arg#--mode=}" ;;
    --order-ids=*) ORDER_IDS_ARG="${arg#--order-ids=}" ;;
    --limit=*)     LIMIT_ARG="${arg#--limit=}" ;;
  esac
done

log "=== picklist-ops: start (mode=${MODE}, batch_size=${BATCH_SIZE}, time_limit=${TIME_LIMIT_HOURS}h) ==="

# ══════════════════════════════════════════════════════════════════════
# STATE HELPERS
# ══════════════════════════════════════════════════════════════════════

state_get() {
  local key="$1"
  if [[ -f "$STATE_FILE" ]]; then
    jq -r --arg k "$key" '.[$k] // empty' "$STATE_FILE" 2>/dev/null || true
  fi
}

state_set() {
  local key="$1" val="$2"
  local current="{}"
  [[ -f "$STATE_FILE" ]] && current=$(cat "$STATE_FILE" 2>/dev/null || echo "{}")
  printf '%s' "$current" | jq --arg k "$key" --arg v "$val" '.[$k] = $v' > "$STATE_FILE"
}

state_clear() {
  local key="$1"
  local current="{}"
  [[ -f "$STATE_FILE" ]] && current=$(cat "$STATE_FILE" 2>/dev/null || echo "{}")
  printf '%s' "$current" | jq --arg k "$key" 'del(.[$k])' > "$STATE_FILE"
}

# ══════════════════════════════════════════════════════════════════════
# FETCH ORDERS
# ══════════════════════════════════════════════════════════════════════

# fetch_orders <since_epoch> [limit]
# Returns JSON array of orders from BaseLinker in ready status
fetch_orders() {
  local since="${1:-0}" limit="${2:-0}"
  local orders

  if [[ -n "$READY_STATUS_ID" ]]; then
    log "Fetching orders with status_id=${READY_STATUS_ID} since epoch ${since}"
    orders=$(bl_get_orders "$since" "$READY_STATUS_ID" 2>/dev/null || printf '[]')
  else
    log "WARNING: BL_PICKLIST_STATUS_ID not set — fetching all recent orders (last 2h)"
    orders=$(bl_get_orders "$since" 2>/dev/null || printf '[]')
  fi

  [[ -z "$orders" ]] && orders="[]"

  if (( limit > 0 )); then
    orders=$(printf '%s' "$orders" | jq --argjson n "$limit" '.[0:$n]')
  fi

  printf '%s' "$orders"
}

# ══════════════════════════════════════════════════════════════════════
# HTML GENERATION
# ══════════════════════════════════════════════════════════════════════

generate_picklist_html() {
  local orders_json="$1"
  local batch_id="$2"
  local mode_label="$3"
  local order_count
  order_count=$(printf '%s' "$orders_json" | jq 'length')
  local date_str
  date_str=$(date '+%d/%m/%Y %H:%M')
  local app_url="${APP_URL:-}"

  # ── SKU grouping via jq ──────────────────────────────────────────
  local sku_rows_json
  sku_rows_json=$(printf '%s' "$orders_json" | jq '
    [ .[] | .order_id as $oid |
      (.products // []) | .[] |
      {
        order_id: ($oid | tostring),
        sku:      (.sku // (.storage_id // "N/A") // "N/A"),
        name:     (.name // "Unknown"),
        qty:      ((.quantity // 1) | tonumber)
      }
    ] |
    group_by(.sku) |
    map({
      sku:       (.[0].sku),
      name:      (.[0].name),
      total_qty: ([.[].qty] | add),
      orders:    ([.[].order_id] | unique | join(", "))
    }) |
    sort_by(.sku)
  ')

  # ── Build SKU table rows ─────────────────────────────────────────
  local sku_table_rows=""
  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    local sku name total_qty orders_str
    sku=$(printf '%s' "$row" | jq -r '.sku')
    name=$(printf '%s' "$row" | jq -r '.name')
    total_qty=$(printf '%s' "$row" | jq -r '.total_qty')
    orders_str=$(printf '%s' "$row" | jq -r '.orders')
    sku_table_rows="${sku_table_rows}
    <tr>
      <td class=\"check\"><input type=\"checkbox\" checked></td>
      <td class=\"sku\">${sku}</td>
      <td class=\"name\">${name}</td>
      <td class=\"qty\">${total_qty}</td>
      <td class=\"orders\">${orders_str}</td>
    </tr>"
  done < <(printf '%s' "$sku_rows_json" | jq -c '.[]')

  # ── Build order summary rows ─────────────────────────────────────
  local order_table_rows=""
  while IFS= read -r order; do
    [[ -z "$order" ]] && continue
    local oid cust_name item_count
    oid=$(printf '%s' "$order" | jq -r '.order_id')
    cust_name=$(printf '%s' "$order" | jq -r '.delivery_fullname // .buyer_login // "Unknown"')
    item_count=$(printf '%s' "$order" | jq '[.products // [] | .[].quantity // 1 | tonumber] | add // 0')
    order_table_rows="${order_table_rows}
    <tr>
      <td class=\"check\"><input type=\"checkbox\" checked></td>
      <td class=\"oid\">#${oid}</td>
      <td>${cust_name}</td>
      <td class=\"qty\">${item_count}</td>
    </tr>"
  done < <(printf '%s' "$orders_json" | jq -c '.[]')

  # ── QR code section ──────────────────────────────────────────────
  local pack_url="" qr_section=""
  if [[ -n "$app_url" ]]; then
    pack_url="${app_url}/picklist/batch/${batch_id}"
    # URL-encode for the QR service query param
    local encoded_url
    encoded_url=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$pack_url" 2>/dev/null \
      || printf '%s' "$pack_url" | sed 's/ /%20/g; s/#/%23/g; s/&/%26/g; s/=/%3D/g; s/?/%3F/g')

    qr_section=$(cat <<QRSEC
<div class="qr-section">
  <img class="qr-img"
       src="https://api.qrserver.com/v1/create-qr-code/?size=160x160&data=${encoded_url}"
       alt="Pack Station QR Code">
  <div class="qr-text">
    <strong>Pack Station — Scan to Print Shipping Labels</strong>
    <p>Scan this QR code at the pack station to open the label printing page for all ${order_count} orders in this batch.</p>
    <div class="qr-url">${pack_url}</div>
  </div>
</div>
QRSEC
)
  fi

  # ── HTML output ──────────────────────────────────────────────────
  cat <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width">
<title>Pick List — ${date_str}</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: 'Helvetica Neue', Arial, sans-serif;
    font-size: 12px;
    color: #111;
    background: #fff;
    padding: 12mm 14mm;
  }

  /* ── Header ── */
  .header {
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
    border-bottom: 2px solid #111;
    padding-bottom: 10px;
    margin-bottom: 16px;
  }
  .header h1 { font-size: 22px; font-weight: 700; letter-spacing: -0.5px; }
  .header .meta { font-size: 11px; color: #555; margin-top: 4px; }
  .header .meta strong { color: #111; }
  .header-right { text-align: right; font-size: 11px; color: #444; line-height: 1.9; }
  .header-right .field-label { display: inline-block; min-width: 90px; }
  .underline { display: inline-block; border-bottom: 1px solid #aaa; min-width: 140px; }

  /* ── Section headings ── */
  h2 {
    font-size: 11px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.8px;
    color: #555;
    border-bottom: 1px solid #ddd;
    padding-bottom: 4px;
    margin: 18px 0 8px;
  }

  /* ── Tables ── */
  table { width: 100%; border-collapse: collapse; margin-bottom: 10px; }
  th {
    background: #f0f0f0;
    font-size: 10px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.5px;
    text-align: left;
    padding: 5px 7px;
    border: 1px solid #ccc;
  }
  td {
    padding: 6px 7px;
    border: 1px solid #ddd;
    vertical-align: middle;
  }
  tr:nth-child(even) td { background: #fafafa; }

  .check { width: 22px; text-align: center; }
  input[type="checkbox"] { width: 14px; height: 14px; cursor: pointer; }
  .sku { font-family: 'Courier New', monospace; font-size: 11px; width: 110px; }
  .oid { font-family: 'Courier New', monospace; font-size: 11px; }
  .name { }
  .qty {
    text-align: center;
    font-weight: 700;
    font-size: 15px;
    width: 52px;
    color: #111;
  }
  .orders { font-size: 10px; color: #555; width: 200px; }

  /* ── QR section ── */
  .qr-section {
    margin-top: 22px;
    padding: 12px 14px;
    border: 1.5px solid #bbb;
    border-radius: 4px;
    display: flex;
    align-items: flex-start;
    gap: 16px;
    page-break-inside: avoid;
  }
  .qr-img { display: block; flex-shrink: 0; }
  .qr-text strong {
    display: block;
    font-size: 13px;
    font-weight: 700;
    margin-bottom: 5px;
  }
  .qr-text p { font-size: 11px; color: #444; line-height: 1.4; }
  .qr-url {
    font-family: 'Courier New', monospace;
    font-size: 9px;
    color: #777;
    word-break: break-all;
    margin-top: 8px;
  }

  /* ── Print overrides ── */
  @media print {
    body { padding: 0; }
    .no-print { display: none !important; }
    input[type="checkbox"] { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
    tr:nth-child(even) td { background: #f8f8f8 !important; print-color-adjust: exact; }
    th { background: #e8e8e8 !important; print-color-adjust: exact; }
    @page { margin: 12mm; size: A4 portrait; }
    h2 { page-break-after: avoid; }
    table { page-break-inside: auto; }
    tr { page-break-inside: avoid; }
  }
</style>
</head>
<body>

<!-- Header -->
<div class="header">
  <div class="header-left">
    <h1>ArryBarry Pick List</h1>
    <div class="meta">
      Batch: <strong>${batch_id}</strong> &nbsp;&bull;&nbsp;
      Mode: <strong>${mode_label}</strong> &nbsp;&bull;&nbsp;
      Orders: <strong>${order_count}</strong> &nbsp;&bull;&nbsp;
      Printed: <strong>${date_str}</strong>
    </div>
  </div>
  <div class="header-right">
    <div><span class="field-label">Picker:</span><span class="underline">&nbsp;</span></div>
    <div><span class="field-label">Started:</span><span class="underline">&nbsp;</span></div>
    <div><span class="field-label">Finished:</span><span class="underline">&nbsp;</span></div>
    <div><span class="field-label">Checked by:</span><span class="underline">&nbsp;</span></div>
  </div>
</div>

<!-- SKU-grouped pick items -->
<h2>Items to Pick — Grouped by SKU</h2>
<table>
  <thead>
    <tr>
      <th class="check">&#10003;</th>
      <th class="sku">SKU</th>
      <th class="name">Product Name</th>
      <th class="qty">Qty</th>
      <th class="orders">In Orders</th>
    </tr>
  </thead>
  <tbody>
    ${sku_table_rows}
  </tbody>
</table>

<!-- Order summary -->
<h2>Order Summary (${order_count} orders)</h2>
<table>
  <thead>
    <tr>
      <th class="check">&#10003;</th>
      <th class="oid">Order #</th>
      <th>Customer</th>
      <th class="qty">Items</th>
    </tr>
  </thead>
  <tbody>
    ${order_table_rows}
  </tbody>
</table>

${qr_section}

</body>
</html>
HTML
}

# ══════════════════════════════════════════════════════════════════════
# PRINT PICKLIST (generate + save + vault)
# ══════════════════════════════════════════════════════════════════════

print_picklist() {
  local orders_json="$1"
  local mode_label="$2"
  local order_count
  order_count=$(printf '%s' "$orders_json" | jq 'length')

  if (( order_count == 0 )); then
    log "picklist-ops: no orders to print — skipping"
    return 0
  fi

  local batch_id
  batch_id="batch-$(date '+%Y%m%d-%H%M%S')"
  local date_iso
  date_iso=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  local date_ymd
  date_ymd=$(date '+%Y-%m-%d')

  log "picklist-ops: generating ${mode_label} picklist (batch=${batch_id}, orders=${order_count})"

  # Generate HTML
  local html
  html=$(generate_picklist_html "$orders_json" "$batch_id" "$mode_label")

  # Save HTML for web serving
  local html_file="${BATCHES_DIR}/${batch_id}.html"
  printf '%s' "$html" > "$html_file"
  log "picklist-ops: HTML saved to ${html_file}"

  # Save batch manifest (JSON)
  local order_ids_json
  order_ids_json=$(printf '%s' "$orders_json" | jq '[.[].order_id | tostring]')
  jq -n \
    --arg batch_id  "$batch_id" \
    --arg mode      "$mode_label" \
    --arg created   "$date_iso" \
    --argjson ids   "$order_ids_json" \
    '{batch_id: $batch_id, mode: $mode, created_at: $created, order_count: ($ids|length), order_ids: $ids}' \
    > "${BATCHES_DIR}/${batch_id}.json"

  # Write vault record
  local vault_path="07-Marketplace/Picklists/${date_ymd}-${batch_id}.md"
  local order_ids_str
  order_ids_str=$(printf '%s' "$order_ids_json" | jq -r 'join(", ")')
  local vault_content
  vault_content=$(cat <<VAULTEOF
---
type: picklist
batch_id: ${batch_id}
mode: ${mode_label}
order_count: ${order_count}
date: ${date_ymd}
created: ${date_iso}
status: generated
---

# Picklist ${batch_id}

**Mode:** ${mode_label}
**Orders:** ${order_count}
**Generated:** ${date_iso}

## Orders

${order_ids_str}
VAULTEOF
)
  vault_write "$vault_path" "$vault_content" 2>/dev/null || log "picklist-ops: vault write failed (non-fatal)"

  # Update state
  state_set "last_batch_epoch" "$(date +%s)"
  state_set "last_batch_id"    "$batch_id"
  state_clear "batch_start_epoch"

  log "picklist-ops: batch ${batch_id} written — ${order_count} orders"
  printf '%s\n' "$batch_id"
}

# ══════════════════════════════════════════════════════════════════════
# MODE: AUTO — threshold check + time-limit fallback
# ══════════════════════════════════════════════════════════════════════

run_auto() {
  # Only look at orders from the past 2 hours to avoid re-processing old ones
  local since
  since=$(( $(date +%s) - 7200 ))

  local orders
  orders=$(fetch_orders "$since" 0)
  local order_count
  order_count=$(printf '%s' "$orders" | jq 'length')
  log "picklist-ops: ${order_count} ready orders found"

  local now
  now=$(date +%s)
  local batch_start
  batch_start=$(state_get "batch_start_epoch")

  if (( order_count >= BATCH_SIZE )); then
    # Threshold hit — print the next BATCH_SIZE orders
    log "picklist-ops: threshold reached (${order_count} >= ${BATCH_SIZE}) — printing"
    local print_orders
    print_orders=$(printf '%s' "$orders" | jq --argjson n "$BATCH_SIZE" '.[0:$n]')
    print_picklist "$print_orders" "auto-batch"

  elif (( order_count > 0 )); then
    # Some orders but not enough — manage time-limit timer
    if [[ -z "$batch_start" ]]; then
      # Start the batch accumulation timer
      state_set "batch_start_epoch" "$now"
      log "picklist-ops: batch timer started — ${order_count} orders waiting for ${BATCH_SIZE}"
    else
      local elapsed
      elapsed=$(( now - batch_start ))
      local limit_secs
      limit_secs=$(( TIME_LIMIT_HOURS * 3600 ))

      if (( elapsed >= limit_secs )); then
        log "picklist-ops: time limit reached (${elapsed}s >= ${limit_secs}s) — printing ${order_count} orders"
        print_picklist "$orders" "time-limit"
      else
        local remaining=$(( limit_secs - elapsed ))
        local remaining_min=$(( remaining / 60 ))
        log "picklist-ops: waiting — ${order_count} orders accumulated, ${remaining_min}m until time-limit"
      fi
    fi

  else
    # No orders — clear the batch timer
    if [[ -n "$batch_start" ]]; then
      state_clear "batch_start_epoch"
      log "picklist-ops: no ready orders — batch timer cleared"
    else
      log "picklist-ops: no ready orders"
    fi
  fi
}

# ══════════════════════════════════════════════════════════════════════
# MODE: MORNING — all overnight orders, no size cap
# ══════════════════════════════════════════════════════════════════════

run_morning() {
  local since
  local last_batch
  last_batch=$(state_get "last_batch_epoch")

  if [[ -n "$last_batch" ]]; then
    since="$last_batch"
    log "picklist-ops: morning batch — fetching orders since last batch ($(date -d "@${since}" '+%Y-%m-%d %H:%M' 2>/dev/null || date -r "${since}" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "epoch ${since}"))"
  else
    # Default: orders from the past 12 hours
    since=$(( $(date +%s) - 43200 ))
    log "picklist-ops: morning batch — no prior batch found, using last 12h window"
  fi

  local orders
  orders=$(fetch_orders "$since" 0)
  local order_count
  order_count=$(printf '%s' "$orders" | jq 'length')
  log "picklist-ops: morning batch — ${order_count} orders to print"

  print_picklist "$orders" "morning-batch"
}

# ══════════════════════════════════════════════════════════════════════
# MODE: MANUAL — specific order IDs or next N
# ══════════════════════════════════════════════════════════════════════

run_manual() {
  local since
  since=$(( $(date +%s) - 86400 ))
  local orders

  if [[ -n "$ORDER_IDS_ARG" ]]; then
    log "picklist-ops: manual mode — fetching specified order IDs"
    local ids_json
    ids_json=$(printf '%s' "$ORDER_IDS_ARG" | tr ',' '\n' | jq -R . | jq -s '.')
    local all_orders
    all_orders=$(fetch_orders "$since" 0)
    orders=$(printf '%s' "$all_orders" | jq --argjson ids "$ids_json" \
      '[.[] | select(.order_id | tostring | IN($ids[]))]')
  else
    local limit="${LIMIT_ARG:-$BATCH_SIZE}"
    log "picklist-ops: manual mode — fetching next ${limit} ready orders"
    orders=$(fetch_orders "$since" "$limit")
  fi

  local order_count
  order_count=$(printf '%s' "$orders" | jq 'length')
  log "picklist-ops: manual mode — ${order_count} orders"
  print_picklist "$orders" "manual"
}

# ══════════════════════════════════════════════════════════════════════
# DISPATCH
# ══════════════════════════════════════════════════════════════════════

case "$MODE" in
  auto)    run_auto ;;
  morning) run_morning ;;
  manual)  run_manual ;;
  *)
    log "ERROR: unknown mode '${MODE}' — use auto|morning|manual"
    exit 1
    ;;
esac

log "=== picklist-ops: done ==="
