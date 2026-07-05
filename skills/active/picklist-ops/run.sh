#!/usr/bin/env bash
set -euo pipefail

# picklist-ops/run.sh — Warehouse picklist automation
# Runs as: doppler run -p shared-services -c prd -- ./run.sh <mode> [args]
#
# Modes:
#   overnight              — batch all orders since yesterday 18:00 before warehouse opens
#   daytime                — batch by threshold (≥PICKLIST_BATCH_SIZE) or time-limit fallback
#   next25                 — manual: print next 25 from queue
#   selected <ids_csv>     — manual: print specific order IDs (comma-separated)
#   scan-return <pl_id>    — picker scanned completed picklist; auto-print shipping labels
#
# Required Doppler vars:
#   BASELINKER_API_TOKEN         — BaseLinker API key
#   PICKLIST_READY_STATUS_IDS    — comma-separated BL status_id values for "ready to pick"
#
# Optional Doppler vars:
#   PICKLIST_BATCH_SIZE          — orders per daytime batch (default: 25)
#   PICKLIST_MAX_WAIT_MINS       — daytime time-limit fallback in minutes (default: 15)
#   PICKLIST_PRINT_CMD           — shell command to print HTML file, e.g. "lpr -P warehouse"
#   PICKLIST_LABEL_PRINTER_ID    — BaseLinker printer ID for auto-label print
#   PICKLIST_COURIER_ID          — BaseLinker courier code for auto-package creation
#   WAREHOUSE_OPEN_HOUR          — hour warehouse opens (default: 8)
#   WAREHOUSE_CLOSE_HOUR         — hour warehouse closes (default: 18)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/../marketplace-lib" && pwd)"

source "${LIB_DIR}/config.sh"
source "${LIB_DIR}/cache.sh"
source "${LIB_DIR}/baselinker.sh"
source "${LIB_DIR}/alerts.sh"
source "${SCRIPT_DIR}/state.sh"
source "${SCRIPT_DIR}/picklist-gen.sh"
source "${SCRIPT_DIR}/labels.sh"

# ── Config defaults ───────────────────────────────────────────────────
PICKLIST_BATCH_SIZE="${PICKLIST_BATCH_SIZE:-25}"
PICKLIST_MAX_WAIT_MINS="${PICKLIST_MAX_WAIT_MINS:-15}"
WAREHOUSE_OPEN_HOUR="${WAREHOUSE_OPEN_HOUR:-8}"
WAREHOUSE_CLOSE_HOUR="${WAREHOUSE_CLOSE_HOUR:-18}"

MODE="${1:-}"
if [[ -z "$MODE" ]]; then
  log "ERROR: mode required (overnight|daytime|next25|selected|scan-return)"
  exit 1
fi

log "=== picklist-ops: starting (mode: ${MODE}) ==="

state_init

# ── Helpers ───────────────────────────────────────────────────────────

# _fetch_ready_orders <since_epoch> [status_ids_csv]
# Fetch orders from BaseLinker that have a ready-to-pick status.
# Prints JSON array of order objects.
_fetch_ready_orders() {
  local since="$1"
  local status_ids_csv="${2:-${PICKLIST_READY_STATUS_IDS:-}}"

  if [[ -z "$status_ids_csv" ]]; then
    log "_fetch_ready_orders: PICKLIST_READY_STATUS_IDS not set — fetching all statuses"
  fi

  local all_orders="[]"

  # Fetch per status_id (BaseLinker filters by one status at a time)
  if [[ -n "$status_ids_csv" ]]; then
    while IFS=',' read -r status_id; do
      status_id=$(printf '%s' "$status_id" | tr -d ' ')
      [[ -z "$status_id" ]] && continue
      log "_fetch_ready_orders: fetching status_id=${status_id} since ${since}"
      local batch
      batch=$(bl_get_orders "$since" "$status_id" || printf '[]')
      [[ -z "$batch" ]] && batch='[]'
      all_orders=$(printf '%s\n%s' "$all_orders" "$batch" | jq -s 'add')
    done <<< "$(printf '%s' "$status_ids_csv" | tr ',' '\n')"
  else
    # No status filter — fetch all orders since timestamp
    local batch
    batch=$(bl_get_orders "$since" || printf '[]')
    [[ -z "$batch" ]] && batch='[]'
    all_orders="$batch"
  fi

  local total
  total=$(printf '%s' "$all_orders" | jq 'length')
  log "_fetch_ready_orders: fetched ${total} orders total"
  printf '%s' "$all_orders"
}

# _make_and_print_picklist <type> <orders_json>
# Core routine: save picklist, generate HTML, print.
# Prints picklist_id to stdout.
_make_and_print_picklist() {
  local type="$1" orders_json="$2"

  local order_count
  order_count=$(printf '%s' "$orders_json" | jq 'length')

  if (( order_count == 0 )); then
    log "_make_and_print_picklist: no orders — skipping"
    return 0
  fi

  local pl_id
  pl_id=$(state_next_picklist_id)
  log "_make_and_print_picklist: creating ${pl_id} (${order_count} orders, type: ${type})"

  # Persist picklist in state
  state_save_picklist "$pl_id" "$type" "$orders_json"

  # Generate HTML picklist
  local html_path
  html_path=$(picklist_build "$pl_id" "$type" "$orders_json")

  # Send to printer
  picklist_print "$html_path"

  # Mark printed in state
  state_mark_printed "$pl_id" "$html_path"

  # Record last batch time
  state_set_last_batch

  log "_make_and_print_picklist: ${pl_id} complete — HTML at ${html_path}"
  printf '%s' "$pl_id"
}

# ══════════════════════════════════════════════════════════════════════
# MODE: overnight
# ══════════════════════════════════════════════════════════════════════
# Fetch all orders since yesterday 18:00 (end of previous working day).
# Group by SKU: all orders for the same SKU stay in one batch (no mid-SKU cap).
# One picklist per "natural grouping" — SKUs are sorted to minimise travel.
mode_overnight() {
  log "mode_overnight: starting overnight picklist batch"

  # Calculate since: yesterday 18:00 local time
  local yesterday_close
  yesterday_close=$(date -d "yesterday ${WAREHOUSE_CLOSE_HOUR}:00" '+%s' 2>/dev/null || \
    date -v-1d -v${WAREHOUSE_CLOSE_HOUR}H -v0M -v0S '+%s' 2>/dev/null || \
    printf '%d' "$(( $(date +%s) - 86400 ))")

  local last_fetch
  last_fetch=$(state_get_last_fetch)

  # Use the later of yesterday-close and last-fetch (avoids re-fetching if run twice)
  local since
  if (( last_fetch > yesterday_close )); then
    since="$last_fetch"
    log "mode_overnight: using last-fetch=${since} (more recent than yesterday ${WAREHOUSE_CLOSE_HOUR}:00)"
  else
    since="$yesterday_close"
    log "mode_overnight: fetching since yesterday ${WAREHOUSE_CLOSE_HOUR}:00 (epoch ${since})"
  fi

  local orders
  orders=$(_fetch_ready_orders "$since")
  state_set_last_fetch "$(date +%s)"

  local order_count
  order_count=$(printf '%s' "$orders" | jq 'length')
  log "mode_overnight: ${order_count} orders to process"

  if (( order_count == 0 )); then
    log "mode_overnight: no overnight orders — nothing to print"
    return 0
  fi

  # Overnight strategy: keep same-SKU orders together, no hard cap per picklist.
  # Group all products by SKU, then pack picklists greedily:
  # a picklist "closes" only when switching to a new SKU would exceed 2x batch size
  # AND we've already passed PICKLIST_BATCH_SIZE — this prevents endless single-SKU lists
  # while honouring the "no cap mid-SKU" rule.

  # Build SKU→orders mapping for grouping decisions
  local sku_to_orders
  sku_to_orders=$(printf '%s' "$orders" | jq '
    reduce (.[] | . as $order | .products[]? |
      {
        sku: (.sku // .product_id // "NO-SKU" | tostring),
        order: $order
      }
    ) as $item (
      {};
      .[$item.sku] //= [] |
      .[$item.sku] += [$item.order]
    )
  ')

  # Sort SKUs to group by bin location for efficient picking (SKUs sorted by location)
  local sorted_skus
  sorted_skus=$(printf '%s' "$orders" | jq -r '
    [.[] | .products[]? |
      {sku: (.sku // .product_id // "NO-SKU" | tostring),
       loc: (.location // .warehouse_location // "ZZZ")}
    ] |
    unique_by(.sku) |
    sort_by(.loc, .sku) |
    .[].sku
  ')

  # Pack orders into picklists, keeping same-SKU together
  local current_batch="[]"
  local current_batch_size=0
  local picklist_count=0

  while IFS= read -r sku; do
    [[ -z "$sku" ]] && continue

    # Get unique orders for this SKU (dedup by order_id)
    local sku_orders
    sku_orders=$(printf '%s' "$sku_to_orders" | jq \
      --arg sku "$sku" \
      '(.[$sku] // []) | unique_by(.order_id)')
    local sku_order_count
    sku_order_count=$(printf '%s' "$sku_orders" | jq 'length')

    # If adding this SKU would push us well over limit AND we already have a full batch,
    # flush current batch first
    if (( current_batch_size >= PICKLIST_BATCH_SIZE && sku_order_count > 0 )); then
      local pl_id
      pl_id=$(_make_and_print_picklist "overnight" "$current_batch")
      log "mode_overnight: flushed picklist ${pl_id} (${current_batch_size} orders)"
      picklist_count=$((picklist_count + 1))
      current_batch="[]"
      current_batch_size=0
    fi

    # Merge this SKU's orders into current batch (dedup by order_id across SKUs)
    current_batch=$(printf '%s\n%s' "$current_batch" "$sku_orders" | jq -s '
      add | unique_by(.order_id)
    ')
    current_batch_size=$(printf '%s' "$current_batch" | jq 'length')

  done <<< "$sorted_skus"

  # Flush final batch
  if (( current_batch_size > 0 )); then
    local pl_id
    pl_id=$(_make_and_print_picklist "overnight" "$current_batch")
    log "mode_overnight: flushed final picklist ${pl_id} (${current_batch_size} orders)"
    picklist_count=$((picklist_count + 1))
  fi

  log "mode_overnight: complete — ${picklist_count} picklist(s) generated for ${order_count} orders"
}

# ══════════════════════════════════════════════════════════════════════
# MODE: daytime
# ══════════════════════════════════════════════════════════════════════
# Called every 10 minutes during business hours via cron.
# 1. Fetch new orders and enqueue them.
# 2. If queue ≥ PICKLIST_BATCH_SIZE → print a batch immediately.
# 3. If time since last batch ≥ PICKLIST_MAX_WAIT_MINS and queue > 0 → print what we have.
# 4. Otherwise, wait for next poll.
mode_daytime() {
  local current_hour
  current_hour=$(date '+%H' | sed 's/^0//')
  if (( current_hour < WAREHOUSE_OPEN_HOUR || current_hour >= WAREHOUSE_CLOSE_HOUR )); then
    log "mode_daytime: outside warehouse hours (${current_hour}h, ops ${WAREHOUSE_OPEN_HOUR}–${WAREHOUSE_CLOSE_HOUR}) — skipping"
    return 0
  fi

  log "mode_daytime: polling for new orders"

  # Fetch new orders since last fetch
  local last_fetch
  last_fetch=$(state_get_last_fetch)
  local since
  # If never run, start from beginning of today
  if (( last_fetch == 0 )); then
    since=$(date -d 'today 00:00' '+%s' 2>/dev/null || date -v0H -v0M -v0S '+%s' 2>/dev/null || \
      printf '%d' "$(( $(date +%s) - 3600 * WAREHOUSE_OPEN_HOUR ))")
  else
    since="$last_fetch"
  fi

  local new_orders
  new_orders=$(_fetch_ready_orders "$since")
  state_set_last_fetch "$(date +%s)"

  local new_count
  new_count=$(printf '%s' "$new_orders" | jq 'length')
  log "mode_daytime: ${new_count} new orders fetched"

  # Enqueue new orders (dedup handled in state_enqueue_orders)
  if (( new_count > 0 )); then
    state_enqueue_orders "$new_orders" > /dev/null
  fi

  local queue_depth
  queue_depth=$(state_queue_count)
  log "mode_daytime: queue depth = ${queue_depth}"

  if (( queue_depth == 0 )); then
    log "mode_daytime: queue empty — nothing to batch"
    return 0
  fi

  local now last_batch elapsed_mins
  now=$(date +%s)
  last_batch=$(state_get_last_batch)
  elapsed_mins=$(( (now - last_batch) / 60 ))

  local should_print=false
  local print_reason=""

  if (( queue_depth >= PICKLIST_BATCH_SIZE )); then
    should_print=true
    print_reason="threshold reached (${queue_depth} ≥ ${PICKLIST_BATCH_SIZE})"
  elif (( last_batch == 0 || elapsed_mins >= PICKLIST_MAX_WAIT_MINS )); then
    should_print=true
    print_reason="time-limit fallback (${elapsed_mins}min elapsed, ${queue_depth} orders pending)"
  fi

  if $should_print; then
    log "mode_daytime: printing batch — ${print_reason}"
    local batch
    batch=$(state_dequeue_batch "$PICKLIST_BATCH_SIZE")
    local batch_count
    batch_count=$(printf '%s' "$batch" | jq 'length')

    if (( batch_count > 0 )); then
      _make_and_print_picklist "daytime" "$batch"
      log "mode_daytime: batch printed (${batch_count} orders)"

      # If queue still has orders >= batch size, print another
      queue_depth=$(state_queue_count)
      while (( queue_depth >= PICKLIST_BATCH_SIZE )); do
        log "mode_daytime: queue still at ${queue_depth} — printing another batch"
        batch=$(state_dequeue_batch "$PICKLIST_BATCH_SIZE")
        batch_count=$(printf '%s' "$batch" | jq 'length')
        (( batch_count > 0 )) && _make_and_print_picklist "daytime" "$batch"
        queue_depth=$(state_queue_count)
      done
    fi
  else
    log "mode_daytime: holding — ${queue_depth} orders queued, ${elapsed_mins}min since last batch (limit: ${PICKLIST_MAX_WAIT_MINS}min)"
  fi

  log "mode_daytime: done (queue remaining: $(state_queue_count))"
}

# ══════════════════════════════════════════════════════════════════════
# MODE: next25
# ══════════════════════════════════════════════════════════════════════
# Print next PICKLIST_BATCH_SIZE orders from the queue.
# If queue is empty, fetches fresh orders first.
mode_next25() {
  log "mode_next25: manual print of next ${PICKLIST_BATCH_SIZE}"

  local queue_depth
  queue_depth=$(state_queue_count)

  if (( queue_depth == 0 )); then
    log "mode_next25: queue empty — fetching fresh orders"
    local last_fetch
    last_fetch=$(state_get_last_fetch)
    (( last_fetch == 0 )) && last_fetch=$(( $(date +%s) - 86400 ))
    local new_orders
    new_orders=$(_fetch_ready_orders "$last_fetch")
    state_set_last_fetch "$(date +%s)"
    local new_count
    new_count=$(printf '%s' "$new_orders" | jq 'length')
    if (( new_count > 0 )); then
      state_enqueue_orders "$new_orders" > /dev/null
      queue_depth=$(state_queue_count)
      log "mode_next25: enqueued ${new_count} new orders"
    fi
  fi

  queue_depth=$(state_queue_count)
  if (( queue_depth == 0 )); then
    log "mode_next25: no orders available to print"
    return 0
  fi

  local batch
  batch=$(state_dequeue_batch "$PICKLIST_BATCH_SIZE")
  _make_and_print_picklist "next25" "$batch"
}

# ══════════════════════════════════════════════════════════════════════
# MODE: selected <order_ids_csv>
# ══════════════════════════════════════════════════════════════════════
# Print a picklist for specific order IDs.
# First looks for them in the queue; if not queued, fetches from BaseLinker directly.
mode_selected() {
  local ids_csv="${2:-}"
  if [[ -z "$ids_csv" ]]; then
    log "mode_selected: no order IDs provided"
    exit 1
  fi

  log "mode_selected: printing picklist for orders: ${ids_csv}"

  # Try to pull from queue first
  local queued_orders
  queued_orders=$(state_dequeue_selected "$ids_csv")
  local queued_count
  queued_count=$(printf '%s' "$queued_orders" | jq 'length')

  # Build list of IDs not found in queue
  local ids_json
  ids_json=$(printf '%s' "$ids_csv" | tr ',' '\n' | jq -R 'tonumber' | jq -s '.')
  local found_ids
  found_ids=$(printf '%s' "$queued_orders" | jq '[.[].order_id]')
  local missing_ids
  missing_ids=$(printf '%s' "$ids_json" | jq \
    --argjson found "$found_ids" \
    '[.[] | select(. as $id | $found | index($id) == null)]')
  local missing_count
  missing_count=$(printf '%s' "$missing_ids" | jq 'length')

  local extra_orders="[]"
  if (( missing_count > 0 )); then
    log "mode_selected: ${missing_count} order(s) not in queue — fetching from BaseLinker"
    # Fetch recent orders and filter to just the missing IDs
    local recent_since
    recent_since=$(( $(date +%s) - 7 * 86400 ))  # last 7 days
    local recent
    recent=$(_fetch_ready_orders "$recent_since")
    extra_orders=$(printf '%s' "$recent" | jq \
      --argjson ids "$missing_ids" \
      '[.[] | select(.order_id as $id | $ids | index($id) != null)]')
    local extra_count
    extra_count=$(printf '%s' "$extra_orders" | jq 'length')
    log "mode_selected: found ${extra_count} of ${missing_count} missing orders in BaseLinker"
  fi

  # Combine
  local all_orders
  all_orders=$(printf '%s\n%s' "$queued_orders" "$extra_orders" | jq -s 'add | unique_by(.order_id)')
  local total
  total=$(printf '%s' "$all_orders" | jq 'length')

  if (( total == 0 )); then
    log "mode_selected: no orders found — nothing to print"
    return 0
  fi

  _make_and_print_picklist "selected" "$all_orders"
  log "mode_selected: picklist printed for ${total} orders"
}

# ══════════════════════════════════════════════════════════════════════
# MODE: scan-return <picklist_id>
# ══════════════════════════════════════════════════════════════════════
# Triggered when a picker scans the QR code on a completed picklist.
# Calls BaseLinker to auto-print shipping labels for all orders in the picklist.
mode_scan_return() {
  local pl_id="${2:-}"
  if [[ -z "$pl_id" ]]; then
    log "mode_scan-return: no picklist_id provided"
    exit 1
  fi

  # Strip "PICKLIST:" prefix if scanner includes it
  pl_id="${pl_id#PICKLIST:}"

  log "mode_scan-return: picker returned with ${pl_id}"
  labels_print_for_picklist "$pl_id"
  log "mode_scan-return: complete"
}

# ══════════════════════════════════════════════════════════════════════
# DISPATCH
# ══════════════════════════════════════════════════════════════════════
case "$MODE" in
  overnight)    mode_overnight ;;
  daytime)      mode_daytime ;;
  next25)       mode_next25 ;;
  selected)     mode_selected "$@" ;;
  scan-return)  mode_scan_return "$@" ;;
  *)
    log "ERROR: unknown mode '${MODE}' — valid: overnight|daytime|next25|selected|scan-return"
    exit 1
    ;;
esac

log "=== picklist-ops: done (mode: ${MODE}) ==="
