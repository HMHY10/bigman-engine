#!/usr/bin/env bash
# picklist-ops/picklist-lib.sh — Core library for picklist automation
# Source this in all picklist-ops scripts (after cd-ing to SCRIPT_DIR)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../marketplace-lib" && pwd)"

source "${LIB_DIR}/config.sh"
source "${LIB_DIR}/cache.sh"
source "${LIB_DIR}/baselinker.sh"
source "${LIB_DIR}/alerts.sh"

# ── Configuration (overridable via env) ──────────────────────────────
PICKLIST_BATCH_SIZE="${PICKLIST_BATCH_SIZE:-25}"
PICKLIST_BATCH_MAX_WAIT="${PICKLIST_BATCH_MAX_WAIT:-15}"         # minutes
PICKLIST_OUTPUT_DIR="${PICKLIST_OUTPUT_DIR:-/opt/bigman-engine/picklists}"
BL_BIN_FIELD="${BL_BIN_FIELD:-extra_field_1}"
# BL_STATUS_NEW — BaseLinker status_id for "ready to pick"; leave empty to fetch all
# BL_STATUS_PICKING — set on orders assigned to a picklist
# BL_STATUS_PICKED  — set on orders when picklist is returned/scanned
# PICKLIST_WEBHOOK_URL — base URL for QR scan-back (e.g. https://bot.arrybarry.com)
# PRINTER_NAME       — CUPS name for A4 picklist sheets
# LABEL_PRINTER_NAME — CUPS name for shipping labels

PICKLIST_STATE_DIR="${STATE_BASE}/picklist-ops"
mkdir -p "$PICKLIST_STATE_DIR" "$PICKLIST_OUTPUT_DIR" \
         "${PICKLIST_STATE_DIR}/picklists"

# ── Generate a unique picklist ID ─────────────────────────────────────
pl_id() {
  printf 'PL-%s' "$(date -u '+%Y%m%d-%H%M%S')"
}

# ── Fetch orders pending a picklist from BaseLinker ───────────────────
# Uses BL_STATUS_NEW if set; otherwise fetches all confirmed unfulfilled orders.
# Args: $1 — since timestamp (Unix epoch, default 24 h ago)
pl_fetch_pending() {
  local since="${1:-$(( $(date +%s) - 86400 ))}"

  log "pl_fetch_pending: since=${since} status=${BL_STATUS_NEW:-any}"
  bl_get_orders "$since" "${BL_STATUS_NEW:-}"
}

# ── Group a JSON order array by SKU ───────────────────────────────────
# Returns a JSON array of objects, sorted by SKU:
#   [{sku, product_name, product_id, inventory_id, bin_location, total_quantity,
#     order_count, orders:[{order_id, quantity, buyer}]}, ...]
pl_group_by_sku() {
  local orders="$1"

  printf '%s' "$orders" | jq '
    [.[] |
      .order_id as $oid |
      (.delivery_fullname // .billing_fullname // "Unknown") as $buyer |
      (.products // [])[] |
      {
        sku:          (.sku // .name // "NO-SKU"),
        product_name: (.name // ""),
        quantity:     ((.quantity // 1) | tonumber),
        order_id:     $oid,
        buyer:        $buyer,
        product_id:   (.storage_product_id // .product_id // null),
        inventory_id: (.inventory_id // null)
      }
    ] |
    group_by(.sku) |
    map({
      sku:            .[0].sku,
      product_name:   .[0].product_name,
      product_id:     .[0].product_id,
      inventory_id:   .[0].inventory_id,
      bin_location:   "—",
      total_quantity: ([.[].quantity] | add),
      order_count:    length,
      orders:         [.[] | {order_id, quantity, buyer}]
    }) |
    sort_by(.sku)
  '
}

# ── Enrich SKU groups with bin/location from product extra fields ─────
# Calls getInventoryProductsData in batches of 100 per inventory.
# Writes bin_location into each SKU group in-place.
pl_enrich_bins() {
  local sku_groups="$1"
  local bin_field="${BL_BIN_FIELD:-extra_field_1}"
  local enriched="$sku_groups"

  # Collect unique inventory IDs that have a product_id
  local inv_ids
  inv_ids=$(printf '%s' "$sku_groups" | jq -r \
    '[.[] | select(.product_id != null and .inventory_id != null) | .inventory_id] | unique[]')

  while IFS= read -r inv_id; do
    [[ -z "$inv_id" ]] && continue

    # Collect product IDs for this inventory
    local prod_ids_arr batch_ids batch_count bin_map
    prod_ids_arr=$(printf '%s' "$sku_groups" | jq -c \
      --argjson inv "$inv_id" \
      '[.[] | select(.inventory_id == $inv and .product_id != null) | .product_id]')

    local prod_count
    prod_count=$(printf '%s' "$prod_ids_arr" | jq 'length')
    (( prod_count == 0 )) && continue

    bin_map="{}"
    batch_ids="[]"
    batch_count=0

    _flush_bin_batch() {
      local n
      n=$(printf '%s' "$batch_ids" | jq 'length')
      (( n == 0 )) && return
      local prod_data
      prod_data=$(bl_request "getInventoryProductsData" \
        "{\"inventory_id\": ${inv_id}, \"products\": $(printf '%s' "$batch_ids")}" \
        2>/dev/null || printf '%s' '{"products":{}}')
      [[ -z "$prod_data" ]] && prod_data='{"products":{}}'

      local batch_bins
      batch_bins=$(printf '%s' "$prod_data" | jq -c \
        --arg field "$bin_field" \
        '[.products // {} | to_entries[] |
          {key: .key, value: (.value[$field] // "—")}
         ] | from_entries')

      bin_map=$(printf '%s\n%s' "$bin_map" "$batch_bins" | jq -s 'add // {}')
      batch_ids="[]"
      batch_count=0
    }

    while IFS= read -r pid; do
      [[ -z "$pid" ]] && continue
      batch_ids=$(printf '%s' "$batch_ids" | jq --argjson p "$pid" '. + [$p]')
      batch_count=$(( batch_count + 1 ))
      (( batch_count >= 100 )) && _flush_bin_batch
    done < <(printf '%s' "$prod_ids_arr" | jq -r '.[]')
    _flush_bin_batch

    enriched=$(printf '%s' "$enriched" | jq -c \
      --argjson bins "$bin_map" \
      --argjson inv "$inv_id" \
      '[.[] | if (.inventory_id == $inv and .product_id != null) then
          .bin_location = ($bins[(.product_id | tostring)] // "—")
        else . end]')

    log "pl_enrich_bins: inv=${inv_id} enriched ${prod_count} products"
  done <<< "$inv_ids"

  printf '%s' "$enriched"
}

# ── Generate printer-ready HTML for a picklist ────────────────────────
# Args: $1 picklist_id  $2 sku_groups_json  $3 order_ids_json
pl_generate_html() {
  local picklist_id="$1"
  local sku_groups="$2"
  local order_ids="$3"

  local total_orders total_skus total_units date_str
  total_orders=$(printf '%s' "$order_ids"  | jq 'length')
  total_skus=$(printf '%s'   "$sku_groups" | jq 'length')
  total_units=$(printf '%s'  "$sku_groups" | jq '[.[].total_quantity] | add // 0')
  date_str=$(date '+%d %B %Y %H:%M')

  # QR code encodes picklist ID; scan-return webhook decodes it
  local qr_data qr_src
  qr_data=$(printf '%s' "$picklist_id" | jq -Rr @uri)
  if [[ -n "${PICKLIST_WEBHOOK_URL:-}" ]]; then
    local scan_url
    scan_url="${PICKLIST_WEBHOOK_URL}/webhook/picklist-scan?id=${qr_data}"
    qr_src="https://api.qrserver.com/v1/create-qr-code/?size=150x150&data=$(printf '%s' "$scan_url" | jq -Rr @uri)"
  else
    qr_src="https://api.qrserver.com/v1/create-qr-code/?size=150x150&data=${qr_data}"
  fi

  # Build the <tbody> rows — one header per SKU, one data row per order
  local tbody=""
  while IFS= read -r sku_entry; do
    [[ -z "$sku_entry" ]] && continue

    local sku pname bin total_qty order_count
    sku=$(        printf '%s' "$sku_entry" | jq -r '.sku')
    pname=$(      printf '%s' "$sku_entry" | jq -r '.product_name // ""')
    bin=$(        printf '%s' "$sku_entry" | jq -r '.bin_location // "—"')
    total_qty=$(  printf '%s' "$sku_entry" | jq -r '.total_quantity')
    order_count=$(printf '%s' "$sku_entry" | jq -r '.order_count')

    local plural=""
    (( order_count != 1 )) && plural="s"

    tbody+="
<tr class=\"sku-hdr\">
  <td colspan=\"3\">
    <div class=\"sku-top\">
      <span class=\"sku-code\">${sku}</span>
      <span class=\"sku-name\">${pname}</span>
    </div>
    <div class=\"sku-badges\">
      <span class=\"badge bin\">\xF0\x9F\x93\xA6 ${bin}</span>
      <span class=\"badge count\">${order_count} order${plural} &middot; pick&nbsp;${total_qty}</span>
    </div>
  </td>
</tr>"

    while IFS= read -r order; do
      [[ -z "$order" ]] && continue
      local o_id o_qty o_buyer
      o_id=$(   printf '%s' "$order" | jq -r '.order_id')
      o_qty=$(   printf '%s' "$order" | jq -r '.quantity')
      o_buyer=$( printf '%s' "$order" | jq -r '.buyer // "—"')
      tbody+="
<tr class=\"order-row\">
  <td class=\"order-id\">#${o_id}</td>
  <td class=\"buyer\">${o_buyer}</td>
  <td class=\"qty\">${o_qty}</td>
</tr>"
    done < <(printf '%s' "$sku_entry" | jq -c '.orders[]')

    tbody+="<tr class=\"spacer\"><td colspan=\"3\"></td></tr>"
  done < <(printf '%s' "$sku_groups" | jq -c '.[]')

  local order_ids_str
  order_ids_str=$(printf '%s' "$order_ids" | jq -r 'map("#\(.)") | join("  ")' )

  cat <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Picklist ${picklist_id}</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:Arial,sans-serif;font-size:11pt;color:#000;background:#fff;padding:12px}
@media print{body{padding:0}.no-print{display:none!important}}

.header{display:flex;justify-content:space-between;align-items:flex-start;
  padding-bottom:10px;border-bottom:2px solid #000;margin-bottom:10px}
.header h1{font-size:17pt;font-weight:bold}
.pl-id{font-family:monospace;font-size:13pt;font-weight:bold;margin-top:3px}
.meta{font-size:9pt;color:#555;margin-top:3px}
.qr img{width:115px;height:115px;border:1px solid #ccc}
.qr-label{font-size:7pt;color:#777;text-align:center;margin-top:2px}

.summary{display:flex;gap:20px;margin-bottom:10px;padding:8px 10px;
  background:#f4f4f4;border-radius:4px}
.sum-item strong{display:block;font-size:14pt;font-weight:bold}
.sum-item{font-size:9pt;color:#444}

.info-box{margin-bottom:10px;padding:7px 10px;border:2px solid #0077cc;
  border-radius:4px;background:#f0f8ff;font-size:10pt}
.info-box b{display:block;margin-bottom:3px}

table{width:100%;border-collapse:collapse}
thead th{background:#1a1a1a;color:#fff;padding:5px 8px;font-size:9pt;text-align:left}

tr.sku-hdr td{background:#ddeef7;padding:7px 8px;border-top:2px solid #0077cc}
.sku-top{display:flex;align-items:baseline;gap:8px}
.sku-code{font-family:monospace;font-weight:bold;font-size:11pt}
.sku-name{font-size:9pt;color:#444}
.sku-badges{margin-top:4px;display:flex;gap:8px}
.badge{padding:2px 8px;border-radius:3px;font-size:10pt;font-weight:bold}
.badge.bin{background:#e65100;color:#fff}
.badge.count{background:#0077cc;color:#fff}

tr.order-row td{padding:4px 8px 4px 18px;border-bottom:1px solid #eee;font-size:9.5pt}
.order-id{font-family:monospace;font-weight:bold;width:90px}
.qty{width:40px;font-weight:bold;text-align:right}
tr.spacer td{height:6px}

.footer{margin-top:12px;padding-top:8px;border-top:1px solid #ccc;
  font-size:8pt;color:#888;display:flex;justify-content:space-between}
</style>
</head>
<body>

<div class="header">
  <div>
    <h1>ArryBarry &mdash; Picklist</h1>
    <div class="pl-id">${picklist_id}</div>
    <div class="meta">Printed: ${date_str}</div>
  </div>
  <div class="qr">
    <img src="${qr_src}" alt="Scan to confirm pick">
    <div class="qr-label">Scan on return</div>
  </div>
</div>

<div class="summary">
  <div class="sum-item"><strong>${total_orders}</strong> Orders</div>
  <div class="sum-item"><strong>${total_skus}</strong> SKUs</div>
  <div class="sum-item"><strong>${total_units}</strong> Units</div>
</div>

<div class="info-box">
  <b>Instructions</b>
  Pick all items below. Items are grouped by SKU — collect all units of each SKU before moving to the next.
  Check the orange bin label for location. When picking is complete, scan the QR code at the dispatch station.
</div>

<table>
<thead>
<tr>
  <th>Order ID</th>
  <th>Buyer</th>
  <th style="text-align:right">Qty</th>
</tr>
</thead>
<tbody>
${tbody}
</tbody>
</table>

<div class="footer">
  <span>${picklist_id}</span>
  <span>ArryBarry Health &amp; Beauty &mdash; Internal Use Only</span>
  <span>${order_ids_str}</span>
</div>

</body>
</html>
HTML
}

# ── Save picklist state to disk ───────────────────────────────────────
pl_save_state() {
  local picklist_id="$1" order_ids="$2" sku_groups="$3"
  local state_file="${PICKLIST_STATE_DIR}/picklists/${picklist_id}.json"

  jq -n \
    --arg  id        "$picklist_id" \
    --arg  ts        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --argjson orders "$order_ids" \
    --argjson skus   "$sku_groups" \
    '{picklist_id: $id, created_at: $ts, status: "picking",
      order_ids: $orders, sku_groups: $skus}' \
    > "$state_file"

  log "pl_save_state: ${picklist_id} saved ($(printf '%s' "$order_ids" | jq 'length') orders)"
}

# ── Load picklist state from disk ─────────────────────────────────────
pl_load_state() {
  local picklist_id="$1"
  local state_file="${PICKLIST_STATE_DIR}/picklists/${picklist_id}.json"
  [[ -f "$state_file" ]] || { log "pl_load_state: not found: ${picklist_id}"; return 1; }
  cat "$state_file"
}

# ── Update picklist status in state file ─────────────────────────────
pl_set_picklist_status() {
  local picklist_id="$1" new_status="$2"
  local state_file="${PICKLIST_STATE_DIR}/picklists/${picklist_id}.json"
  [[ -f "$state_file" ]] || return 1

  local updated
  updated=$(jq --arg s "$new_status" '.status = $s' "$state_file")
  printf '%s' "$updated" > "$state_file"
  log "pl_set_picklist_status: ${picklist_id} → ${new_status}"
}

# ── Update order status in BaseLinker ─────────────────────────────────
pl_set_order_status() {
  local order_id="$1" status_id="$2"
  [[ -z "$status_id" ]] && return 0

  local params
  params=$(jq -n --argjson oid "$order_id" --argjson sid "$status_id" \
    '{order_id: $oid, status_id: $sid}')

  bl_request "setOrderStatus" "$params" >/dev/null || {
    log "pl_set_order_status: failed for order ${order_id} → ${status_id}"
    return 1
  }
  log "pl_set_order_status: order ${order_id} → ${status_id}"
}

# ── Write HTML to output dir (and optionally send to printer) ─────────
pl_print_picklist() {
  local picklist_id="$1" html_content="$2"
  local output_file="${PICKLIST_OUTPUT_DIR}/${picklist_id}.html"

  printf '%s' "$html_content" > "$output_file"
  log "pl_print_picklist: wrote ${output_file}"

  if [[ -n "${PRINTER_NAME:-}" ]]; then
    if command -v lpr >/dev/null 2>&1; then
      lpr -P "$PRINTER_NAME" -o media=A4 -o fit-to-page "$output_file" \
        && log "pl_print_picklist: sent to printer ${PRINTER_NAME}" \
        || log "pl_print_picklist: lpr failed"
    else
      log "pl_print_picklist: PRINTER_NAME set but lpr not found"
    fi
  fi

  printf '%s' "$output_file"
}

# ── Write a vault note summarising this picklist ─────────────────────
pl_vault_record() {
  local picklist_id="$1" order_ids="$2" sku_groups="$3"

  local order_list sku_list
  order_list=$(printf '%s' "$order_ids" | jq -r 'map("- #\(.)") | join("\n")')
  sku_list=$(printf '%s' "$sku_groups" | jq -r \
    '.[] | "- **\(.sku)** — \(.order_count) order(s), \(.total_quantity) unit(s), bin: \(.bin_location)"' )

  local content
  content=$(cat <<VEOF
---
source: picklist-ops
type: picklist
picklist_id: ${picklist_id}
created: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
status: picking
orders: $(printf '%s' "$order_ids" | jq 'length')
---

# Picklist ${picklist_id}

**Created:** $(date -u '+%Y-%m-%d %H:%M UTC')
**Status:** Picking in progress

## Orders

${order_list}

## SKUs

${sku_list}
VEOF
)
  vault_write "07-Marketplace/Picklists/${picklist_id}.md" "$content" \
    || log "pl_vault_record: vault write failed (non-critical)"
}

# ── Core: build a picklist from a JSON order array ────────────────────
# Handles grouping, bin enrichment, HTML generation, printing, state, vault.
# Prints the picklist_id on success.
pl_create_picklist() {
  local orders="$1"
  local order_count
  order_count=$(printf '%s' "$orders" | jq 'length')

  if (( order_count == 0 )); then
    log "pl_create_picklist: no orders, skipping"
    return 0
  fi

  local picklist_id
  picklist_id=$(pl_id)
  log "pl_create_picklist: ${picklist_id} — ${order_count} orders"

  local order_ids sku_groups html
  order_ids=$(printf '%s' "$orders" | jq '[.[].order_id]')
  sku_groups=$(pl_group_by_sku "$orders")
  sku_groups=$(pl_enrich_bins  "$sku_groups")

  pl_save_state     "$picklist_id" "$order_ids" "$sku_groups"
  html=$(pl_generate_html "$picklist_id" "$sku_groups" "$order_ids")
  pl_print_picklist "$picklist_id" "$html"
  pl_vault_record   "$picklist_id" "$order_ids" "$sku_groups"

  # Advance BaseLinker status to "picking"
  if [[ -n "${BL_STATUS_PICKING:-}" ]]; then
    while IFS= read -r oid; do
      [[ -z "$oid" ]] && continue
      pl_set_order_status "$oid" "$BL_STATUS_PICKING" || true
    done < <(printf '%s' "$order_ids" | jq -r '.[]')
  fi

  log "pl_create_picklist: ${picklist_id} complete"
  printf '%s\n' "$picklist_id"
}

# ── Fetch + print shipping label for a single order ───────────────────
# Tries existing packages first; creates one if none found.
pl_print_shipping_label() {
  local order_id="$1"
  log "pl_print_shipping_label: order ${order_id}"

  # Attempt to fetch existing packages
  local pkgs_raw pkg_id
  pkgs_raw=$(bl_request "getOrderPackages" \
    "$(jq -n --argjson oid "$order_id" '{order_id: $oid}')" 2>/dev/null \
    || printf '%s' '{"packages":[]}')
  [[ -z "$pkgs_raw" ]] && pkgs_raw='{"packages":[]}'

  pkg_id=$(printf '%s' "$pkgs_raw" | jq -r '(.packages // []) | .[0].package_id // empty')

  if [[ -z "$pkg_id" ]]; then
    log "pl_print_shipping_label: no package for order ${order_id}, creating..."
    local created
    created=$(bl_request "createPackage" \
      "$(jq -n --argjson oid "$order_id" '{order_id: $oid, courier_code: "other"}')" \
      2>/dev/null || printf '%s' '{}')
    pkg_id=$(printf '%s' "$created" | jq -r '.package_id // empty')
  fi

  if [[ -z "$pkg_id" ]]; then
    log "pl_print_shipping_label: could not obtain package_id for order ${order_id}"
    return 1
  fi

  # Fetch label
  local label_raw label_b64 label_file
  label_raw=$(bl_request "getCourierLabel" \
    "$(jq -n --argjson pid "$pkg_id" '{package_id: $pid, label_format: "pdf"}')" \
    2>/dev/null || printf '%s' '{}')

  label_b64=$(printf '%s' "$label_raw" | jq -r '.label // empty')

  if [[ -z "$label_b64" ]]; then
    log "pl_print_shipping_label: empty label response for order ${order_id}"
    return 1
  fi

  label_file="${PICKLIST_OUTPUT_DIR}/label-${order_id}.pdf"
  printf '%s' "$label_b64" | base64 -d > "$label_file" 2>/dev/null || {
    log "pl_print_shipping_label: base64 decode failed for order ${order_id}"
    return 1
  }

  log "pl_print_shipping_label: saved ${label_file}"

  if [[ -n "${LABEL_PRINTER_NAME:-}" ]] && command -v lpr >/dev/null 2>&1; then
    lpr -P "$LABEL_PRINTER_NAME" "$label_file" \
      && log "pl_print_shipping_label: printed to ${LABEL_PRINTER_NAME}" \
      || log "pl_print_shipping_label: lpr failed"
  fi

  printf '%s' "$label_file"
}
