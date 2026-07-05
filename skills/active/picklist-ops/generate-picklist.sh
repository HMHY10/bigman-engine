#!/usr/bin/env bash
# picklist-ops/generate-picklist.sh — Core picklist generation logic
#
# Usage (sourced from run.sh, morning-batch.sh):
#   generate_picklist <orders_json> <batch_label>
#
#   orders_json   — JSON array of BaseLinker order objects
#   batch_label   — short label for vault note title, e.g. "auto-25" or "morning"
#
# Outputs picklist_id to stdout on success.
# All diagnostics go to stderr via log().
#
# Requires: config.sh, cache.sh, baselinker.sh, alerts.sh sourced first.
# Requires: STATE_DIR, PICKLIST_WEBHOOK_URL, PICKLIST_PICKING_STATUS_ID set.

# ── Increment and return next picklist ID ────────────────────────────
_next_picklist_id() {
  local counter_file="${STATE_DIR}/picklist-counter"
  local id=1
  if [[ -f "$counter_file" ]]; then
    id=$(cat "$counter_file" 2>/dev/null || echo 0)
    id=$((id + 1))
  fi
  printf '%d' "$id" > "$counter_file"
  printf '%03d' "$id"
}

# ── URL-encode a string ──────────────────────────────────────────────
_urlencode() {
  local str="$1"
  printf '%s' "$str" | python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read().strip(), safe=''))"
}

# ── Generate QR code as base64 PNG data URI ──────────────────────────
# Falls back to a plain-text URL if qrencode is not installed.
_qr_image() {
  local data="$1"
  if command -v qrencode &>/dev/null; then
    local b64
    b64=$(qrencode -t PNG -s 4 -m 2 -o - "$data" 2>/dev/null | base64 -w 0)
    if [[ -n "$b64" ]]; then
      printf 'data:image/png;base64,%s' "$b64"
      return 0
    fi
  fi
  # Fallback: use a public QR service URL (requires network when rendering)
  local encoded
  encoded=$(_urlencode "$data")
  printf 'https://api.qrserver.com/v1/create-qr-code/?data=%s&size=150x150' "$encoded"
}

# ── Main generation function ─────────────────────────────────────────
generate_picklist() {
  local orders_json="$1"
  local batch_label="${2:-batch}"

  local order_count
  order_count=$(printf '%s' "$orders_json" | jq 'length')

  if (( order_count == 0 )); then
    log "generate_picklist: no orders — nothing to generate"
    return 1
  fi

  local picklist_id
  picklist_id=$(_next_picklist_id)

  local date_str ts_str
  date_str=$(date '+%Y-%m-%d')
  ts_str=$(date '+%Y-%m-%d %H:%M:%S')

  log "generate_picklist: generating picklist #${picklist_id} (${order_count} orders, ${batch_label})"

  # ── Build SKU map ──────────────────────────────────────────────────
  # For each order, for each product: accumulate qty + order refs per SKU.
  # sku_entries: newline-delimited JSON objects {sku, name, qty, order_id, location}
  local sku_entries
  sku_entries=$(printf '%s' "$orders_json" | jq -c '
    .[] |
    . as $order |
    ($order.products // [])[] |
    {
      sku: (.sku // .product_id // "NO-SKU" | tostring),
      name: (.name // "Unknown Product"),
      qty: (.quantity // 1 | tonumber),
      order_id: ($order.order_id | tostring),
      location: (.warehouse_group // .location // "")
    }
  ')

  # ── Aggregate by SKU ───────────────────────────────────────────────
  local sku_map
  sku_map=$(printf '%s\n' "$sku_entries" | jq -s '
    group_by(.sku) |
    map({
      sku: .[0].sku,
      name: .[0].name,
      location: ([ .[].location | select(. != "") ] | first // ""),
      total_qty: ([ .[].qty ] | add),
      order_refs: (
        group_by(.order_id) |
        map({
          order_id: .[0].order_id,
          qty: ([ .[].qty ] | add)
        })
      )
    }) |
    sort_by([.location, .sku])
  ')

  local sku_count
  sku_count=$(printf '%s' "$sku_map" | jq 'length')

  local total_items
  total_items=$(printf '%s' "$sku_map" | jq '[.[].total_qty] | add // 0')

  # ── Build order ID list for state ─────────────────────────────────
  local order_ids
  order_ids=$(printf '%s' "$orders_json" | jq '[.[].order_id | tostring]')

  # ── Generate QR code for pack station scan ─────────────────────────
  local scan_url qr_image_src
  scan_url="${PICKLIST_WEBHOOK_URL}/api/webhook/picklist-scan"
  local scan_payload
  scan_payload=$(printf '{"picklist_id":"%s"}' "$picklist_id")
  # For QR at pack station: encode picklist ID directly; scanner POSTs to webhook
  qr_image_src=$(_qr_image "${scan_url}?id=${picklist_id}")

  # ── Build SKU sections ─────────────────────────────────────────────
  local sku_sections=""
  local line_num=0

  while IFS= read -r sku_entry; do
    [[ -z "$sku_entry" ]] && continue
    line_num=$((line_num + 1))

    local sku name location total_qty order_refs_str
    sku=$(printf '%s' "$sku_entry" | jq -r '.sku')
    name=$(printf '%s' "$sku_entry" | jq -r '.name')
    location=$(printf '%s' "$sku_entry" | jq -r '.location')
    total_qty=$(printf '%s' "$sku_entry" | jq -r '.total_qty')
    order_refs_str=$(printf '%s' "$sku_entry" | jq -r \
      '.order_refs | map("#\(.order_id) ×\(.qty)") | join(", ")')

    local location_str=""
    [[ -n "$location" ]] && location_str="  **Location:** ${location}  "

    sku_sections="${sku_sections}
### ${line_num}. ${sku} — ${name}

| Field | Value |
|-------|-------|
| **SKU** | \`${sku}\` |
| **Total qty** | **${total_qty}** |${location_str}
| **Orders** | ${order_refs_str} |

- [ ] Picked

---
"
  done < <(printf '%s' "$sku_map" | jq -c '.[]')

  # ── Build order summary table ──────────────────────────────────────
  local order_table_rows=""
  while IFS= read -r order; do
    [[ -z "$order" ]] && continue
    local oid buyer date
    oid=$(printf '%s' "$order" | jq -r '.order_id')
    buyer=$(printf '%s' "$order" | jq -r '.delivery_fullname // .buyer_login // "Unknown"')
    date=$(printf '%s' "$order" | jq -r '
      if .date_add then (.date_add | strftime("%H:%M %d/%m")) else "—" end
    ')
    local items
    items=$(printf '%s' "$order" | jq -r '[.products // [] | .[].quantity // 1 | tonumber] | add // 0')
    order_table_rows="${order_table_rows}| #${oid} | ${buyer} | ${date} | ${items} |
"
  done < <(printf '%s' "$orders_json" | jq -c '.[]')

  # ── Compose full markdown note ─────────────────────────────────────
  local content
  content=$(cat <<PICKLIST_EOF
---
source: picklist-ops
type: picklist
picklist_id: "${picklist_id}"
batch_label: "${batch_label}"
date: "${date_str}"
order_count: ${order_count}
sku_count: ${sku_count}
total_items: ${total_items}
status: open
generated_at: "${ts_str}"
---

# Picklist #${picklist_id} — ${date_str}

> **${order_count} orders** | **${sku_count} SKUs** | **${total_items} items total**
> Generated: ${ts_str} | Batch: ${batch_label}

---

## How to Use

1. Pick items in the order listed below (sorted by location then SKU)
2. Tick each line when picked
3. Take the trolley to the pack station
4. **Scan the QR code below** to trigger shipping label printing for all ${order_count} orders

---

## Pack Station QR

Scan this at the pack station to print all ${order_count} shipping labels:

![Scan to print labels — Picklist #${picklist_id}](${qr_image_src})

> Picklist ID: **${picklist_id}** | URL: \`${scan_url}\`

---

## Pick List (${total_items} items across ${sku_count} SKUs)

${sku_sections}

---

## Orders in This Batch (${order_count})

| Order | Customer | Time | Items |
|-------|----------|------|-------|
${order_table_rows}
---
*Auto-generated by picklist-ops · ${ts_str}*
PICKLIST_EOF
)

  # ── Write to vault ─────────────────────────────────────────────────
  local vault_path="07-Marketplace/Picklists/${date_str}-picklist-${picklist_id}.md"
  vault_write "$vault_path" "$content"
  local vault_rc=$?

  # ── Save picklist state ────────────────────────────────────────────
  local state_dir="${STATE_DIR}/picklists"
  mkdir -p "$state_dir"
  printf '%s' "$(jq -n \
    --arg id "$picklist_id" \
    --arg label "$batch_label" \
    --arg ts "$ts_str" \
    --arg vault "$vault_path" \
    --argjson orders "$order_ids" \
    '{
      picklist_id: $id,
      batch_label: $label,
      generated_at: $ts,
      vault_path: $vault,
      order_ids: $orders,
      status: "open"
    }')" > "${state_dir}/${picklist_id}.json"

  # ── Set orders to "picking" status in BaseLinker ──────────────────
  if [[ -n "${PICKLIST_PICKING_STATUS_ID:-}" ]]; then
    local moved=0 failed=0
    while IFS= read -r order; do
      [[ -z "$order" ]] && continue
      local oid
      oid=$(printf '%s' "$order" | jq -r '.order_id')
      if bl_set_order_status "$oid" "$PICKLIST_PICKING_STATUS_ID"; then
        moved=$((moved + 1))
      else
        log "generate_picklist: failed to set status for order ${oid}"
        failed=$((failed + 1))
      fi
    done < <(printf '%s' "$orders_json" | jq -c '.[]')
    log "generate_picklist: status updates — moved: ${moved}, failed: ${failed}"
  else
    log "generate_picklist: PICKLIST_PICKING_STATUS_ID not set — skipping status updates"
  fi

  if (( vault_rc == 0 )); then
    log "generate_picklist: #${picklist_id} written to vault at ${vault_path}"
  else
    log "generate_picklist: #${picklist_id} state saved but vault write failed"
  fi

  # Return picklist ID to caller
  printf '%s' "$picklist_id"
  return 0
}
