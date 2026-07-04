#!/usr/bin/env bash
# picklist-ops/lib/core.sh — State management, batch IDs, and pending order queue
# Requires: marketplace-lib/config.sh, baselinker.sh sourced first

# ── Paths ────────────────────────────────────────────────────────────────
PICKLIST_STATE_DIR="${STATE_BASE}/picklist"
PICKLIST_BATCHES_DIR="${PICKLIST_STATE_DIR}/batches"
PICKLIST_PRINTS_DIR="${PICKLIST_STATE_DIR}/prints"
PICKLIST_BATCHED_FILE="${PICKLIST_STATE_DIR}/batched-order-ids.txt"
PICKLIST_LAST_BATCH_TIME_FILE="${PICKLIST_STATE_DIR}/last-batch-time"
PICKLIST_LOCATION_CACHE_FILE="${PICKLIST_STATE_DIR}/location-cache.json"

# ── Config defaults ───────────────────────────────────────────────────────
PICKLIST_BATCH_SIZE="${PICKLIST_BATCH_SIZE:-25}"
PICKLIST_TIME_FALLBACK_MINS="${PICKLIST_TIME_FALLBACK_MINS:-30}"
PICKLIST_INVENTORY_ID="${PICKLIST_INVENTORY_ID:-}"

# ── picklist_state_init ──────────────────────────────────────────────────
# Create state directories. Call once at script start.
picklist_state_init() {
  mkdir -p "$PICKLIST_STATE_DIR" "$PICKLIST_BATCHES_DIR" "$PICKLIST_PRINTS_DIR"
  touch "$PICKLIST_BATCHED_FILE"
}

# ── picklist_batch_id_gen ────────────────────────────────────────────────
# Generate the next sequential batch ID for today: PL-YYYYMMDD-NNN
# Reads and increments a per-day sequence counter file.
picklist_batch_id_gen() {
  local date_str
  date_str=$(date '+%Y%m%d')
  local seq_file="${PICKLIST_STATE_DIR}/batch-seq-${date_str}"
  local seq=1

  if [[ -f "$seq_file" ]]; then
    seq=$(( $(cat "$seq_file") + 1 ))
  fi

  printf '%d' "$seq" > "$seq_file"
  printf 'PL-%s-%03d' "$date_str" "$seq"
}

# ── picklist_mark_batched <order_id> ... ─────────────────────────────────
# Record order IDs as batched to prevent double-picking.
picklist_mark_batched() {
  for order_id in "$@"; do
    echo "$order_id" >> "$PICKLIST_BATCHED_FILE"
  done
}

# ── picklist_is_batched <order_id> ───────────────────────────────────────
# Returns 0 if order is already batched, 1 if not.
picklist_is_batched() {
  local order_id="$1"
  grep -qxF "$order_id" "$PICKLIST_BATCHED_FILE" 2>/dev/null
}

# ── picklist_batch_save <batch_id> <batch_json> ──────────────────────────
# Persist batch metadata to state directory.
picklist_batch_save() {
  local batch_id="$1"
  local batch_json="$2"
  printf '%s' "$batch_json" > "${PICKLIST_BATCHES_DIR}/${batch_id}.json"
  log "picklist_batch_save: saved ${batch_id}"
}

# ── picklist_batch_load <batch_id> ───────────────────────────────────────
# Load batch metadata. Prints JSON to stdout.
picklist_batch_load() {
  local batch_id="$1"
  local batch_file="${PICKLIST_BATCHES_DIR}/${batch_id}.json"

  if [[ ! -f "$batch_file" ]]; then
    log "picklist_batch_load: batch ${batch_id} not found"
    return 1
  fi

  cat "$batch_file"
}

# ── picklist_batch_update_status <batch_id> <status> ─────────────────────
# Update the status field of a saved batch (e.g. "generated", "picked").
picklist_batch_update_status() {
  local batch_id="$1"
  local status="$2"
  local batch_file="${PICKLIST_BATCHES_DIR}/${batch_id}.json"

  if [[ ! -f "$batch_file" ]]; then
    log "picklist_batch_update_status: batch ${batch_id} not found"
    return 1
  fi

  local updated
  updated=$(jq --arg s "$status" '.status = $s' "$batch_file")
  printf '%s' "$updated" > "$batch_file"
  log "picklist_batch_update_status: ${batch_id} → ${status}"
}

# ── picklist_update_last_batch_time ──────────────────────────────────────
# Record the current timestamp as the last daytime batch time.
picklist_update_last_batch_time() {
  date +%s > "$PICKLIST_LAST_BATCH_TIME_FILE"
}

# ── picklist_should_force_batch ───────────────────────────────────────────
# Returns 0 if the time-fallback threshold has been reached (force a batch
# regardless of order count). Returns 1 if within the quiet window.
picklist_should_force_batch() {
  local now
  now=$(date +%s)

  if [[ ! -f "$PICKLIST_LAST_BATCH_TIME_FILE" ]]; then
    # No record of last batch — force one
    return 0
  fi

  local last_batch
  last_batch=$(cat "$PICKLIST_LAST_BATCH_TIME_FILE")
  local elapsed_mins=$(( (now - last_batch) / 60 ))

  if (( elapsed_mins >= PICKLIST_TIME_FALLBACK_MINS )); then
    log "picklist_should_force_batch: ${elapsed_mins}m since last batch (threshold ${PICKLIST_TIME_FALLBACK_MINS}m) — forcing"
    return 0
  fi

  log "picklist_should_force_batch: ${elapsed_mins}m since last batch — not yet"
  return 1
}

# ── picklist_fetch_ready_orders ───────────────────────────────────────────
# Fetch all orders in "ready to pick" status from BaseLinker.
# Prints a JSON array of order objects to stdout.
# Args: [since_timestamp] (default: 7 days ago)
picklist_fetch_ready_orders() {
  local since="${1:-}"
  local default_since
  default_since=$(( $(date +%s) - 604800 ))  # 7 days ago
  since="${since:-$default_since}"

  local params
  if [[ -n "${PICKLIST_READY_STATUS_ID:-}" ]]; then
    params=$(jq -n \
      --argjson since "$since" \
      --argjson status "$PICKLIST_READY_STATUS_ID" \
      '{date_from: $since, status_id: $status, get_unconfirmed_orders: false}')
  else
    log "picklist_fetch_ready_orders: PICKLIST_READY_STATUS_ID not set — fetching all confirmed orders"
    params=$(jq -n --argjson since "$since" '{date_from: $since, get_unconfirmed_orders: false}')
  fi

  local all_orders="[]"
  local last_order_id=0
  local page_num=0

  while (( page_num < 50 )); do
    local page_params
    page_params=$(printf '%s' "$params" | jq \
      --argjson last_id "$last_order_id" \
      'if $last_id > 0 then . + {id_from: $last_id} else . end')

    local batch
    batch=$(bl_request "getOrders" "$page_params") || { log "picklist_fetch_ready_orders: request failed"; break; }

    local page_orders count
    page_orders=$(printf '%s' "$batch" | jq -c '.orders // []')
    count=$(printf '%s' "$page_orders" | jq 'length')

    (( count == 0 )) && break

    all_orders=$(printf '%s\n%s' "$all_orders" "$page_orders" | jq -s 'add')
    page_num=$(( page_num + 1 ))
    (( count < 100 )) && break

    last_order_id=$(printf '%s' "$page_orders" | jq '.[-1].order_id')
  done

  local total
  total=$(printf '%s' "$all_orders" | jq 'length')
  log "picklist_fetch_ready_orders: fetched ${total} orders"
  printf '%s' "$all_orders"
}

# ── picklist_filter_unbatched <orders_json> ───────────────────────────────
# Remove orders already assigned to a batch. Prints filtered JSON array.
picklist_filter_unbatched() {
  local orders_json="$1"

  if [[ ! -s "$PICKLIST_BATCHED_FILE" ]]; then
    printf '%s' "$orders_json"
    return 0
  fi

  # Build a jq-compatible array of already-batched IDs
  local batched_ids
  batched_ids=$(awk 'NF' "$PICKLIST_BATCHED_FILE" | jq -R . | jq -s .)

  local filtered
  filtered=$(printf '%s' "$orders_json" | jq \
    --argjson ids "$batched_ids" \
    '[.[] | select((.order_id | tostring) as $id | ($ids | map(tostring) | index($id)) == null)]')

  local before after
  before=$(printf '%s' "$orders_json" | jq 'length')
  after=$(printf '%s' "$filtered" | jq 'length')
  log "picklist_filter_unbatched: ${before} orders → ${after} after removing already-batched"

  printf '%s' "$filtered"
}

# ── picklist_select_batch <orders_json> <batch_size> <extend_sku> ─────────
# Select orders for the next batch.
#   batch_size: target number of orders (0 = take all)
#   extend_sku: 1 = extend batch to include same-SKU orders beyond batch_size
# Prints a JSON array of selected orders.
picklist_select_batch() {
  local orders_json="$1"
  local batch_size="${2:-0}"
  local extend_sku="${3:-1}"

  local total
  total=$(printf '%s' "$orders_json" | jq 'length')

  # No cap: return all orders
  if (( batch_size == 0 || total <= batch_size )); then
    printf '%s' "$orders_json"
    return 0
  fi

  # Sort by order date (oldest first) and take first batch_size
  local initial_batch
  initial_batch=$(printf '%s' "$orders_json" | jq \
    --argjson n "$batch_size" \
    'sort_by(.date_add // 0) | .[:$n]')

  if (( extend_sku == 0 )); then
    printf '%s' "$initial_batch"
    return 0
  fi

  # Collect all SKUs/EANs in the initial batch
  local batch_skus
  batch_skus=$(printf '%s' "$initial_batch" | jq -r \
    '[.[].products[]? | (.sku // .ean // (.product_id | tostring))] | unique | .[]')

  if [[ -z "$batch_skus" ]]; then
    printf '%s' "$initial_batch"
    return 0
  fi

  # Build set of initial order IDs
  local initial_ids
  initial_ids=$(printf '%s' "$initial_batch" | jq '[.[].order_id | tostring]')

  # From remaining orders, find any that share a SKU with the initial batch
  local skus_json
  skus_json=$(printf '%s' "$batch_skus" | jq -R . | jq -s .)

  local extras
  extras=$(printf '%s' "$orders_json" | jq \
    --argjson ids "$initial_ids" \
    --argjson skus "$skus_json" \
    '[.[] |
      select((.order_id | tostring) as $oid | ($ids | index($oid)) == null) |
      select(
        .products[]? |
        (.sku // .ean // (.product_id | tostring)) as $s |
        ($skus | index($s)) != null
      )] | unique_by(.order_id)')

  local extra_count
  extra_count=$(printf '%s' "$extras" | jq 'length')

  if (( extra_count > 0 )); then
    log "picklist_select_batch: extended batch by ${extra_count} same-SKU orders beyond ${batch_size} cap"
  fi

  # Merge initial + extras
  printf '%s' "$initial_batch" "$extras" | jq -s 'add | unique_by(.order_id)'
}

# ── picklist_build_sku_groups <orders_json> <location_map_json> ───────────
# Consolidate order line items into SKU groups.
# Returns JSON array: [{sku, ean, name, location, quantity, order_ids}]
picklist_build_sku_groups() {
  local orders_json="$1"
  local location_map="${2:-{}}"  # JSON object: {sku: "location", ...}

  printf '%s' "$orders_json" | jq \
    --argjson locs "$location_map" '
    # Flatten all line items, tagging each with its order_id
    [.[].products[]? as $item |
      ($item | .parent_order_id = (.. | .order_id? // empty)) |
      .] |
    # Re-flatten with order tagging
    [range(length) as $i | .[]] as $_ |

    # Group by SKU key (sku, then ean, then product_id)
    (
      reduce (.[] | . as $item | {
        key: ($item.sku // $item.ean // ($item.product_id | tostring)),
        name: ($item.name // "Unknown Product"),
        ean: ($item.ean // ""),
        qty: ($item.quantity // 1),
        oid: ($item.parent_order_id | tostring)
      }) as $x ({};
        .[$x.key] |= (
          if . == null then
            {sku: $x.key, name: $x.name, ean: $x.ean, quantity: $x.qty, order_ids: [$x.oid]}
          else
            .quantity += $x.qty |
            .order_ids += [$x.oid]
          end
        )
      ) | to_entries | map(.value)
    ) |
    # Attach bin locations from cache
    map(. + {location: ($locs[.sku] // $locs[.ean] // "")}) |
    # Sort by location (empty last), then by sku
    sort_by([(if .location == "" then 1 else 0 end), .location, .sku])
  ' 2>/dev/null || \
  # Fallback: simpler grouping without nested jq complexity
  _picklist_build_sku_groups_simple "$orders_json" "$location_map"
}

# Simpler fallback for SKU grouping
_picklist_build_sku_groups_simple() {
  local orders_json="$1"
  local location_map="${2:-{}}"

  local groups="{}"
  local order_id sku name ean qty location

  while IFS= read -r order; do
    [[ -z "$order" ]] && continue
    order_id=$(printf '%s' "$order" | jq -r '.order_id')

    while IFS= read -r item; do
      [[ -z "$item" ]] && continue
      sku=$(printf '%s' "$item" | jq -r '.sku // .ean // (.product_id | tostring) // "UNKNOWN"')
      name=$(printf '%s' "$item" | jq -r '.name // "Unknown Product"')
      ean=$(printf '%s' "$item" | jq -r '.ean // ""')
      qty=$(printf '%s' "$item" | jq -r '.quantity // 1')
      location=$(printf '%s' "$location_map" | jq -r --arg s "$sku" --arg e "$ean" \
        '.[$s] // .[$e] // ""')

      groups=$(printf '%s' "$groups" | jq \
        --arg sku "$sku" --arg name "$name" --arg ean "$ean" \
        --argjson qty "$qty" --arg loc "$location" --arg oid "$order_id" '
        if .[$sku] == null then
          .[$sku] = {sku: $sku, name: $name, ean: $ean, quantity: $qty,
                     location: $loc, order_ids: [$oid]}
        else
          .[$sku].quantity += $qty |
          .[$sku].order_ids += [$oid]
        end')
    done < <(printf '%s' "$order" | jq -c '.products[]? // empty')
  done < <(printf '%s' "$orders_json" | jq -c '.[] // empty')

  printf '%s' "$groups" | jq '[to_entries[].value |
    . + {order_ids: (.order_ids | unique)}] |
    sort_by([(if .location == "" then 1 else 0 end), .location, .sku])'
}

# ── picklist_fetch_locations ──────────────────────────────────────────────
# Build a {sku: location, ean: location} map from BaseLinker inventory.
# Uses a 4-hour cache to avoid hammering the API on every batch.
# Prints JSON object to stdout.
picklist_fetch_locations() {
  local inv_id="${PICKLIST_INVENTORY_ID:-}"

  # Check cache age
  if [[ -f "$PICKLIST_LOCATION_CACHE_FILE" ]]; then
    local cache_age_secs=$(( $(date +%s) - $(stat -c %Y "$PICKLIST_LOCATION_CACHE_FILE" 2>/dev/null || echo 0) ))
    if (( cache_age_secs < 14400 )); then  # 4 hours
      log "picklist_fetch_locations: using cached location map (age: ${cache_age_secs}s)"
      cat "$PICKLIST_LOCATION_CACHE_FILE"
      return 0
    fi
  fi

  if [[ -z "$inv_id" ]]; then
    log "picklist_fetch_locations: PICKLIST_INVENTORY_ID not set — no location data"
    echo "{}"
    return 0
  fi

  log "picklist_fetch_locations: fetching product list from inventory ${inv_id}..."
  local location_map="{}"
  local page=1

  while (( page <= 50 )); do
    local params
    params=$(jq -n --argjson id "$inv_id" --argjson p "$page" \
      '{inventory_id: $id, page: $p}')

    local result
    result=$(bl_request "getInventoryProductsList" "$params" 2>/dev/null) || break

    local count
    count=$(printf '%s' "$result" | jq '.products // {} | length')
    (( count == 0 )) && break

    # Merge {sku: location} and {ean: location} from this page
    location_map=$(printf '%s\n%s' "$location_map" \
      "$(printf '%s' "$result" | jq -c '
        .products // {} | to_entries |
        map(select(.value.location != null and .value.location != "")) |
        map({
          sku: (.value.sku // ""),
          ean: (.value.ean // ""),
          loc: .value.location
        }) |
        reduce .[] as $p ({};
          if $p.sku != "" then .[$p.sku] = $p.loc else . end |
          if $p.ean != "" then .[$p.ean] = $p.loc else . end
        )')" | jq -s 'add')

    log "picklist_fetch_locations: page ${page} — ${count} products"
    (( count < 1000 )) && break
    page=$(( page + 1 ))
  done

  printf '%s' "$location_map" > "$PICKLIST_LOCATION_CACHE_FILE"
  log "picklist_fetch_locations: location cache built"
  printf '%s' "$location_map"
}
