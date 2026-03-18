#!/usr/bin/env bash
# marketplace-lib/baselinker.sh — BaseLinker API client
# Requires: config.sh and cache.sh sourced first

# ── Rate limiter ───────────────────────────────────────────────────────
_bl_rate_wait() {
  (
    flock -w 10 200 || { log "bl_rate: failed to acquire lock"; return 1; }

    touch "$BL_RATE_LOG"
    local now cutoff count
    now=$(date +%s)
    cutoff=$((now - 60))

    # Prune entries older than 60s and count remaining
    local tmp="${BL_RATE_LOG}.tmp"
    awk -v c="$cutoff" '$1 >= c' "$BL_RATE_LOG" > "$tmp" 2>/dev/null
    mv "$tmp" "$BL_RATE_LOG"
    count=$(wc -l < "$BL_RATE_LOG" | tr -d ' ')

    if (( count >= BL_RATE_LIMIT )); then
      local oldest
      oldest=$(head -1 "$BL_RATE_LOG" | awk '{print $1}')
      local wait_secs=$(( oldest + 60 - now + 1 ))
      if (( wait_secs > 0 )); then
        log "bl_rate: limit hit (${count}/${BL_RATE_LIMIT}), sleeping ${wait_secs}s"
        sleep "$wait_secs"
      fi
    fi

    # Record this request
    printf '%d\n' "$(date +%s)" >> "$BL_RATE_LOG"
  ) 200>"$BL_RATE_LOCK"
}

# ── Core request ───────────────────────────────────────────────────────
# bl_request <method> [params_json]
# Returns JSON body on success, empty on failure. Sets BL_LAST_STATUS.
bl_request() {
  local method="$1"
  local params="${2:-\{\}}"
  local max_retries=3
  local attempt=0
  local backoff=2
  local response http_code body bl_status

  while (( attempt < max_retries )); do
    _bl_rate_wait

    response=$(curl -sS -w '\n%{http_code}' \
      -X POST "$BASELINKER_API_URL" \
      -H "X-BLToken: ${BASELINKER_API_TOKEN}" \
      -d "method=${method}&parameters=${params}")

    http_code=$(printf '%s' "$response" | tail -1)
    body=$(printf '%s' "$response" | sed '$d')

    # 429 Too Many Requests
    if [[ "$http_code" == "429" ]]; then
      attempt=$((attempt + 1))
      if (( attempt >= max_retries )); then
        log "bl_request: ${method} 429 after ${max_retries} attempts, giving up"
        return 1
      fi
      log "bl_request: ${method} 429 — sleeping 60s (attempt ${attempt}/${max_retries})"
      sleep 60
      continue
    fi

    # 5xx server error — retry with backoff
    if [[ "$http_code" =~ ^5[0-9]{2}$ ]]; then
      attempt=$((attempt + 1))
      if (( attempt >= max_retries )); then
        log "bl_request: ${method} ${http_code} after ${max_retries} attempts"
        return 1
      fi
      local sleep_time=$(( backoff ** attempt ))
      log "bl_request: ${method} ${http_code} — retry in ${sleep_time}s (attempt ${attempt}/${max_retries})"
      sleep "$sleep_time"
      continue
    fi

    # 4xx client error (not 429) — fail fast
    if [[ "$http_code" =~ ^4[0-9]{2}$ ]]; then
      log "bl_request: ${method} ${http_code} — client error, not retrying"
      return 1
    fi

    # HTTP 200 — check BaseLinker status field
    bl_status=$(printf '%s' "$body" | jq -r '.status // empty')
    if [[ "$bl_status" == "ERROR" ]]; then
      local err_code err_msg
      err_code=$(printf '%s' "$body" | jq -r '.error_code // "unknown"')
      err_msg=$(printf '%s' "$body" | jq -r '.error_message // "no message"')
      log "bl_request: ${method} API error ${err_code}: ${err_msg}"
      return 1
    fi

    BL_LAST_STATUS="$bl_status"
    printf '%s' "$body"
    return 0
  done

  return 1
}

# ── bl_get_orders <since_timestamp> [status_id] ───────────────────────
# Auto-paginate getOrders. Prints full JSON array of orders.
bl_get_orders() {
  local since="$1" status_id="${2:-}"
  local all_orders="[]" page_orders params batch
  local last_order_id=0 page_num=0 max_pages=50

  while (( page_num < max_pages )); do
    params=$(jq -n \
      --argjson since "$since" \
      --argjson last_id "$last_order_id" \
      --arg sid "$status_id" \
      '{date_from: $since, get_unconfirmed_orders: false} |
       if $last_id > 0 then .id_from = $last_id else . end |
       if $sid != "" then .status_id = ($sid | tonumber) else . end')

    batch=$(bl_request "getOrders" "$params") || { log "bl_get_orders: request failed"; break; }
    page_orders=$(printf '%s' "$batch" | jq -c '.orders // []')
    local count
    count=$(printf '%s' "$page_orders" | jq 'length')

    if (( count == 0 )); then
      break
    fi

    all_orders=$(printf '%s\n%s' "$all_orders" "$page_orders" | jq -s 'add')
    page_num=$((page_num + 1))

    # If fewer than 100, we've reached the last page
    if (( count < 100 )); then
      break
    fi

    # Next page: use last order_id as id_from (BaseLinker pagination)
    last_order_id=$(printf '%s' "$page_orders" | jq '.[-1].order_id')
  done

  local total
  total=$(printf '%s' "$all_orders" | jq 'length')
  log "bl_get_orders: fetched ${total} orders in ${page_num} pages since ${since}"
  cache_write "orders" "latest" "$all_orders"
  printf '%s' "$all_orders"
}

# ── bl_get_returns <since_timestamp> ───────────────────────────────────
bl_get_returns() {
  local since="$1" page_token=0
  local all_returns="[]" params batch page_returns count
  local page_num=0 max_pages=50

  while (( page_num < max_pages )); do
    params=$(jq -n \
      --argjson since "$since" \
      --argjson page "$page_token" \
      '{date_from: $since} |
       if $page > 0 then .page = $page else . end')

    batch=$(bl_request "getOrderReturns" "$params") || { log "bl_get_returns: request failed"; break; }
    page_returns=$(printf '%s' "$batch" | jq -c '.returns // []')
    count=$(printf '%s' "$page_returns" | jq 'length')

    if (( count == 0 )); then break; fi
    all_returns=$(printf '%s\n%s' "$all_returns" "$page_returns" | jq -s 'add')
    page_num=$((page_num + 1))
    if (( count < 100 )); then break; fi
    page_token=$(printf '%s' "$page_returns" | jq '.[-1].return_id')
  done

  local total
  total=$(printf '%s' "$all_returns" | jq 'length')
  log "bl_get_returns: fetched ${total} returns since ${since}"
  cache_write "returns" "latest" "$all_returns"
  printf '%s' "$all_returns"
}

# ── bl_get_journal <since_timestamp> ──────────────────────────────────
# Persists last_log_id in STATE_BASE/journal-last-id to avoid re-fetching
# all entries on every run. Falls back to ID 1 if no state file exists.
bl_get_journal() {
  local since="$1"
  local state_file="${STATE_BASE:-/opt/bigman-engine/state}/journal-last-id"
  local last_id=1

  if [[ -f "$state_file" ]]; then
    last_id=$(cat "$state_file" 2>/dev/null || echo 1)
    [[ "$last_id" =~ ^[0-9]+$ ]] || last_id=1
  fi

  local params
  params=$(jq -n --argjson last_id "$last_id" '{last_log_id: $last_id, logs_types: [1,2,3,4,5,6,7,8,9,10]}')
  local result
  result=$(bl_request "getJournalList" "$params") || return 1

  # Filter by timestamp client-side
  local filtered
  filtered=$(printf '%s' "$result" | jq --argjson since "$since" \
    '[.logs // [] | .[] | select(.date >= $since)]')

  # Persist the highest log_id for next run
  local max_id
  max_id=$(printf '%s' "$result" | jq '[.logs // [] | .[].log_id // 0] | max // 0')
  if (( max_id > last_id )); then
    mkdir -p "$(dirname "$state_file")"
    printf '%s' "$max_id" > "$state_file"
    log "bl_get_journal: persisted last_log_id=${max_id}"
  fi

  local total
  total=$(printf '%s' "$filtered" | jq 'length')
  log "bl_get_journal: ${total} entries since ${since} (from log_id ${last_id})"
  printf '%s' "$filtered"
}

# ── bl_get_order_payments <order_id> ──────────────────────────────────
bl_get_order_payments() {
  local order_id="$1"
  local params
  params=$(jq -n --argjson oid "$order_id" '{order_id: $oid}')
  bl_request "getOrderPaymentsHistory" "$params"
}

# ── bl_get_invoices <since_timestamp> ─────────────────────────────────
bl_get_invoices() {
  local since="$1"
  local params
  params=$(jq -n --argjson since "$since" '{date_from: $since}')
  bl_request "getInvoices" "$params"
}

# ── bl_get_purchase_orders ────────────────────────────────────────────
bl_get_purchase_orders() {
  bl_request "getInventoryPurchaseOrders" "{}"
}

# ── bl_get_inventory_documents ────────────────────────────────────────
bl_get_inventory_documents() {
  bl_request "getInventoryDocuments" "{}"
}

# ── bl_get_courier_status <package_ids_json_array> ────────────────────
bl_get_courier_status() {
  local package_ids="$1"
  local params
  params=$(jq -n --argjson ids "$package_ids" '{package_ids: $ids}')
  bl_request "getCourierPackagesStatusHistory" "$params"
}

# ── bl_get_product_stock <inventory_id> ───────────────────────────────
bl_get_product_stock() {
  local inv_id="$1"
  local params
  params=$(jq -n --argjson id "$inv_id" '{inventory_id: $id}')
  bl_request "getInventoryProductsStock" "$params"
}

# ── bl_get_product_prices <inventory_id> ──────────────────────────────
bl_get_product_prices() {
  local inv_id="$1"
  local params
  params=$(jq -n --argjson id "$inv_id" '{inventory_id: $id}')
  bl_request "getInventoryProductsPrices" "$params"
}

# ── bl_get_external_storage_stock <storage_id> ────────────────────────
bl_get_external_storage_stock() {
  local storage_id="$1"
  local params
  params=$(jq -n --arg id "$storage_id" '{storage_id: $id}')
  bl_request "getExternalStorageProductsQuantity" "$params"
}

# ── bl_get_external_storage_prices <storage_id> ───────────────────────
bl_get_external_storage_prices() {
  local storage_id="$1"
  local params
  params=$(jq -n --arg id "$storage_id" '{storage_id: $id}')
  bl_request "getExternalStorageProductsPrices" "$params"
}

# ── bl_get_external_storages ─────────────────────────────────────────
bl_get_external_storages() {
  bl_request "getExternalStoragesList" "{}"
}

# ── bl_get_order_sources ─────────────────────────────────────────────
bl_get_order_sources() {
  bl_request "getOrderSources" "{}"
}

# ── bl_check_po_delivery <po_json> <docs_json> <alert_domain> ────────
# Shared PO-to-delivery matching logic for finance-ops and inventory-ops.
# Returns number of alerts raised via stdout.
# Args:
#   $1 — JSON array of purchase orders
#   $2 — JSON array of inventory documents (goods-in)
#   $3 — Vault alert folder (e.g. "Finance/Alerts" or "Inventory/Alerts")
bl_check_po_delivery() {
  local pos="$1" docs="$2" alert_folder="$3"
  local alert_count=0 short_count=0 late_count=0

  while IFS= read -r po; do
    [[ -z "$po" ]] && continue

    local po_id po_status
    po_id=$(printf '%s' "$po" | jq -r '.purchase_order_id // .id')
    po_status=$(printf '%s' "$po" | jq -r '.status // "unknown"')

    [[ "$po_status" == "draft" || "$po_status" == "cancelled" ]] && continue

    local po_date po_age_days=0
    po_date=$(printf '%s' "$po" | jq -r '.date_add // .date_created // .date // 0')
    if [[ "$po_date" =~ ^[0-9]+$ ]] && (( po_date > 0 )); then
      po_age_days=$(( ($(date +%s) - po_date) / 86400 ))
    fi

    local matching_docs doc_count
    matching_docs=$(printf '%s' "$docs" | jq --arg poid "$po_id" \
      '[.[] | select(.purchase_order_id == ($poid | tonumber) or .purchase_order_id == $poid)]')
    doc_count=$(printf '%s' "$matching_docs" | jq 'length')

    if (( doc_count == 0 )) && (( po_age_days > 14 )); then
      alert_create "high" "baselinker" "$alert_folder" \
        "Late Delivery PO ${po_id}" \
        "**PO ID:** ${po_id}
**PO age:** ${po_age_days} days
**Status:** ${po_status}
**Matching goods-in documents:** 0

Purchase order is ${po_age_days} days old with no corresponding goods-in document."
      late_count=$((late_count + 1))
      alert_count=$((alert_count + 1))
      continue
    fi

    if (( doc_count > 0 )); then
      local po_qty_ordered qty_received
      po_qty_ordered=$(printf '%s' "$po" | jq '[.products // [] | .[].quantity // 0 | tonumber] | add // 0')
      qty_received=$(printf '%s' "$matching_docs" | jq '[.[].products // [] | .[].quantity // 0 | tonumber] | add // 0')

      if bc_gt "$po_qty_ordered" 0 && bc_lt "$qty_received" "$po_qty_ordered"; then
        local shortfall
        shortfall=$(echo "scale=0; $po_qty_ordered - $qty_received" | bc -l)

        alert_create "high" "baselinker" "$alert_folder" \
          "Short Delivery PO ${po_id}" \
          "**PO ID:** ${po_id}
**Quantity ordered:** ${po_qty_ordered}
**Quantity received:** ${qty_received}
**Shortfall:** ${shortfall}
**Status:** ${po_status}"
        short_count=$((short_count + 1))
        alert_count=$((alert_count + 1))
      fi
    fi
  done < <(printf '%s' "$pos" | jq -c '.[]')

  log "bl_check_po_delivery: ${alert_count} alerts (short: ${short_count}, late: ${late_count})"
  printf '%d %d %d' "$alert_count" "$short_count" "$late_count"
}
