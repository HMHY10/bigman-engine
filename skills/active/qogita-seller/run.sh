#!/usr/bin/env bash
set -euo pipefail

# ── qogita-seller/run.sh ─────────────────────────────────────────────
# Sell-side ops for ArryBarry on Qogita wholesale marketplace.
# Usage: ./run.sh              (orders mode — every 2h)
#        ./run.sh --stock-feed (stock feed — daily 5am)

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="/opt/bigman-engine/skills/active/marketplace-lib"

# ── Source shared libraries ──────────────────────────────────────────
source "${LIB_DIR}/config.sh"
source "${LIB_DIR}/cache.sh"
source "${LIB_DIR}/alerts.sh"
source "${LIB_DIR}/qogita-auth.sh"

MODE="${1:-orders}"

# =====================================================================
# MODE: orders (default) — every 2 hours
# =====================================================================
run_orders() {
  log "qogita-seller: starting orders mode"

  # ── 1. Authenticate ────────────────────────────────────────────────
  local token
  token=$(qogita_login "seller")
  if [[ -z "$token" ]]; then
    log "qogita-seller: auth failed, aborting"
    return 1
  fi
  log "qogita-seller: auth success"

  # ── 2. Fetch seller orders ─────────────────────────────────────────
  local orders_json
  orders_json=$(qogita_request "seller" "GET" "/seller/orders/?page=1&size=50") || {
    log "qogita-seller: /seller/orders/ failed, trying /orders/"
    orders_json=$(qogita_request "seller" "GET" "/orders/?page=1&size=50") || {
      log "qogita-seller: order fetch failed on all endpoints"
      log "qogita-seller: response was: ${orders_json:-empty}"
      return 1
    }
  }

  log "qogita-seller: orders response received ($(printf '%s' "$orders_json" | wc -c | tr -d ' ') bytes)"

  # ── 3. Cache the orders ────────────────────────────────────────────
  cache_write "qogita-seller" "orders" "$orders_json"

  # ── 4. Parse orders and check SLA deadlines ────────────────────────
  # Extract results array (Qogita paginates with .results or top-level array)
  local results
  results=$(printf '%s' "$orders_json" | jq -c '.results // . // []')

  local total_orders
  total_orders=$(printf '%s' "$results" | jq 'if type == "array" then length else 0 end')

  # Qogita seller order statuses: CHECKOUT, PAID, FINANCED, EXPIRED, SHIPPED, DELIVERED, CANCELLED
  local count_checkout=0 count_paid=0 count_financed=0 count_expired=0
  local count_shipped=0 count_delivered=0 count_cancelled=0 count_other=0

  local sla_high_alerts=""
  local sla_critical_alerts=""
  local now_epoch
  now_epoch=$(date +%s)

  # Process each order using process substitution
  while IFS= read -r order; do
    [[ -z "$order" || "$order" == "null" ]] && continue

    local status created_at_ms order_id order_fid
    status=$(printf '%s' "$order" | jq -r '.status // "unknown"')
    created_at_ms=$(printf '%s' "$order" | jq -r '.createdAt // empty')
    order_id=$(printf '%s' "$order" | jq -r '.qid // .id // "unknown"')
    order_fid=$(printf '%s' "$order" | jq -r '.fid // empty')

    # Use short fid for display if available
    local display_id="${order_fid:-${order_id}}"

    case "$status" in
      CHECKOUT)    count_checkout=$((count_checkout + 1)) ;;
      PAID)        count_paid=$((count_paid + 1))
        # PAID orders need fulfilment — check SLA
        if [[ -n "$created_at_ms" && "$created_at_ms" != "null" ]]; then
          local created_epoch age_hours
          # createdAt is millisecond epoch — convert to seconds
          created_epoch=$(( created_at_ms / 1000 ))

          if (( created_epoch > 0 )); then
            age_hours=$(( (now_epoch - created_epoch) / 3600 ))

            if (( age_hours >= 36 )); then
              sla_critical_alerts="${sla_critical_alerts}\n- Order ${display_id}: paid ${age_hours}h ago (SLA BREACH)"
            elif (( age_hours >= 24 )); then
              sla_high_alerts="${sla_high_alerts}\n- Order ${display_id}: paid ${age_hours}h ago (approaching SLA)"
            fi
          fi
        fi
        ;;
      FINANCED)    count_financed=$((count_financed + 1))
        # FINANCED orders also need fulfilment — check SLA
        if [[ -n "$created_at_ms" && "$created_at_ms" != "null" ]]; then
          local created_epoch age_hours
          created_epoch=$(( created_at_ms / 1000 ))

          if (( created_epoch > 0 )); then
            age_hours=$(( (now_epoch - created_epoch) / 3600 ))

            if (( age_hours >= 36 )); then
              sla_critical_alerts="${sla_critical_alerts}\n- Order ${display_id}: financed ${age_hours}h ago (SLA BREACH)"
            elif (( age_hours >= 24 )); then
              sla_high_alerts="${sla_high_alerts}\n- Order ${display_id}: financed ${age_hours}h ago (approaching SLA)"
            fi
          fi
        fi
        ;;
      EXPIRED)     count_expired=$((count_expired + 1)) ;;
      SHIPPED)     count_shipped=$((count_shipped + 1)) ;;
      DELIVERED)   count_delivered=$((count_delivered + 1)) ;;
      CANCELLED)   count_cancelled=$((count_cancelled + 1)) ;;
      *)
        count_other=$((count_other + 1))
        log "qogita-seller: unknown status '${status}' for order ${display_id}"
        ;;
    esac
  done < <(printf '%s' "$results" | jq -c '.[]? // empty')

  local actionable=$((count_paid + count_financed))

  # ── Fire SLA alerts ────────────────────────────────────────────────
  if [[ -n "$sla_critical_alerts" ]]; then
    alert_create "critical" "Qogita" "Qogita/Seller/Alerts" \
      "Qogita Seller SLA Breach" \
      "Orders exceeding 36h pending threshold:$(printf '%b' "$sla_critical_alerts")"
  fi

  if [[ -n "$sla_high_alerts" ]]; then
    alert_create "high" "Qogita" "Qogita/Seller/Alerts" \
      "Qogita Seller SLA Warning" \
      "Orders approaching 36h SLA deadline:$(printf '%b' "$sla_high_alerts")"
  fi

  # ── 5. Write daily performance summary to vault ────────────────────
  local today
  today=$(date '+%Y-%m-%d')
  local vault_path="07-Marketplace/Qogita/Seller/${today}-performance.md"

  local summary_content
  summary_content=$(cat <<PERFEOF
---
source: qogita-seller
date: ${today}
type: performance-summary
marketplace: Qogita
role: seller
---

# Qogita Seller Performance — ${today}

## Order Summary

| Status     | Count |
|------------|-------|
| Total      | ${total_orders} |
| Checkout   | ${count_checkout} |
| Paid       | ${count_paid} |
| Financed   | ${count_financed} |
| Shipped    | ${count_shipped} |
| Delivered  | ${count_delivered} |
| Expired    | ${count_expired} |
| Cancelled  | ${count_cancelled} |

**Actionable (need fulfilment):** ${actionable}

## SLA Status

$(if [[ -n "$sla_critical_alerts" ]]; then
    printf '### CRITICAL (>36h awaiting fulfilment)\n%b\n' "$sla_critical_alerts"
  else
    printf 'No critical SLA breaches.\n'
  fi)

$(if [[ -n "$sla_high_alerts" ]]; then
    printf '### HIGH (>24h awaiting fulfilment)\n%b\n' "$sla_high_alerts"
  else
    printf 'No high-priority SLA warnings.\n'
  fi)

## Notes

- Seller account: info@arrybarry.com
- Region: GB only
- Submitted prices exclude Qogita margin (final buyer price differs)
- PAID and FINANCED orders require fulfilment action
- Run timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
PERFEOF
)

  local http_code
  http_code=$(curl -sS -o /dev/null -w '%{http_code}' \
    -X PUT "${VAULT_URL}/vault/${vault_path}" \
    -H "Authorization: Bearer ${OBSIDIAN_API_KEY}" \
    -H "Content-Type: text/markdown" \
    -d "$summary_content")

  if [[ "$http_code" == "204" || "$http_code" == "200" ]]; then
    log "qogita-seller: performance summary written to ${vault_path}"
  else
    log "qogita-seller: vault write failed — HTTP ${http_code}"
  fi

  log "qogita-seller: orders mode complete (total=${total_orders} paid=${count_paid} financed=${count_financed} shipped=${count_shipped} actionable=${actionable})"
}

# =====================================================================
# MODE: --stock-feed — daily at 5am
# =====================================================================
run_stock_feed() {
  log "qogita-seller: starting stock feed mode"

  # Source baselinker for inventory data
  source "${LIB_DIR}/baselinker.sh"

  # ── 1. Get BaseLinker inventories ──────────────────────────────────
  local inventories_json
  inventories_json=$(bl_request "getInventories" "{}") || {
    log "qogita-seller: failed to fetch inventories"
    return 1
  }

  local first_inv_id inv_name
  first_inv_id=$(printf '%s' "$inventories_json" | jq -r '.inventories[0].inventory_id // empty')
  inv_name=$(printf '%s' "$inventories_json" | jq -r '.inventories[0].name // "unknown"')

  if [[ -z "$first_inv_id" ]]; then
    log "qogita-seller: no inventories found"
    return 1
  fi
  log "qogita-seller: using inventory ${first_inv_id} (${inv_name})"

  # ── 2. Get product list (includes EAN, SKU) ─────────────────────────
  local list_params list_json
  list_params=$(jq -n --argjson id "$first_inv_id" '{inventory_id: $id}')
  list_json=$(bl_request "getInventoryProductsList" "$list_params") || {
    log "qogita-seller: failed to fetch product list"
    return 1
  }

  local product_ids
  product_ids=$(printf '%s' "$list_json" | jq -r '.products | keys[]')
  local total_products
  total_products=$(printf '%s' "$list_json" | jq '.products | length')
  log "qogita-seller: found ${total_products} products in inventory"

  if (( total_products == 0 )); then
    log "qogita-seller: no products found, skipping stock feed"
    return 0
  fi

  # ── 3. Get product stock ───────────────────────────────────────────
  local stock_json
  stock_json=$(bl_get_product_stock "$first_inv_id") || {
    log "qogita-seller: failed to fetch product stock"
    return 1
  }

  # ── 4. Get product prices ──────────────────────────────────────────
  local prices_json
  prices_json=$(bl_get_product_prices "$first_inv_id") || {
    log "qogita-seller: failed to fetch product prices"
    return 1
  }

  # ── 5. Generate CSV stock feed ─────────────────────────────────────
  mkdir -p /opt/bigman-engine/outputs

  local csv_file="/opt/bigman-engine/outputs/qogita-stock-feed.csv"
  local product_count=0

  # Generate CSV in a single jq pass (was: 3 jq calls per product × 1000 products)
  printf 'ean,sku,quantity,price\n' > "$csv_file"

  jq -r --argjson stock "$stock_json" --argjson prices "$prices_json" '
    .products | to_entries[] |
    select(.value.ean != null and .value.ean != "") |
    .key as $id |
    .value.ean as $ean |
    (.value.sku // $id) as $sku |
    ([$stock.products[$id].stock // {} | to_entries[].value] | add // 0) as $qty |
    ([$prices.products[$id].prices // {} | to_entries[].value] | first // 0) as $price |
    "\($ean),\($sku),\($qty),\($price)"
  ' <<< "$list_json" >> "$csv_file"

  product_count=$(( $(wc -l < "$csv_file") - 1 ))  # minus header

  log "qogita-seller: stock feed generated — ${product_count} products -> ${csv_file}"

  # ── 6. Cache the feed data ─────────────────────────────────────────
  local feed_meta
  feed_meta=$(jq -n \
    --arg file "$csv_file" \
    --argjson count "$product_count" \
    --arg inv_id "$first_inv_id" \
    --arg inv_name "$inv_name" \
    --arg generated "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '{file: $file, product_count: $count, inventory_id: $inv_id, inventory_name: $inv_name, generated_at: $generated}')

  cache_write "qogita-seller" "stock-feed" "$feed_meta"

  log "qogita-seller: stock feed mode complete"
}

# =====================================================================
# Dispatch
# =====================================================================
case "$MODE" in
  orders)
    run_orders
    ;;
  --stock-feed)
    run_stock_feed
    ;;
  *)
    log "qogita-seller: unknown mode '${MODE}' — use 'orders' (default) or '--stock-feed'"
    exit 1
    ;;
esac

log "qogita-seller: run complete"
