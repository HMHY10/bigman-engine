#!/usr/bin/env bash
set -euo pipefail
# picklist-ops/trigger.sh — Manual picklist triggers (called by API or webhook)
#
# Usage:
#   ./trigger.sh next-25
#       Print the next batch of up to 25 ready orders from the queue.
#
#   ./trigger.sh selected '["12345","12346","12347"]'
#       Print a specific set of order IDs.
#
# Run as: doppler run -p shared-services -c prd -- ./trigger.sh <mode> [args]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../marketplace-lib" && pwd)"

source "${LIB_DIR}/config.sh"
source "${LIB_DIR}/cache.sh"
source "${LIB_DIR}/baselinker.sh"
source "${SCRIPT_DIR}/state.sh"
source "${SCRIPT_DIR}/generate.sh"
source "${SCRIPT_DIR}/print.sh"

BATCH_SIZE="${PICKLIST_BATCH_SIZE:-25}"
PICK_STATUS_ID="${BL_PICK_STATUS_ID:-}"

MODE="${1:-next-25}"
ARG2="${2:-}"

log "=== picklist-ops trigger: mode=${MODE} ==="
state_init

_fetch_and_queue_ready_orders() {
  if [[ -z "$PICK_STATUS_ID" ]]; then
    log "trigger: BL_PICK_STATUS_ID not set — cannot auto-refresh queue"
    return
  fi
  local since
  since=$(( $(date +%s) - 86400 * 30 ))
  local ready_orders
  ready_orders=$(bl_get_orders "$since" "$PICK_STATUS_ID" 2>/dev/null || printf '[]')
  [[ -z "$ready_orders" ]] && ready_orders='[]'
  local unprinted
  unprinted=$(filter_unprinted "$ready_orders")
  local count
  count=$(printf '%s' "$unprinted" | jq 'length')
  if (( count > 0 )); then
    queue_add_orders "$unprinted"
    log "trigger: refreshed queue (+${count} orders)"
  fi
}

_print_batch() {
  local orders_json="$1"
  local mode_label="$2"
  local batch_count
  batch_count=$(printf '%s' "$orders_json" | jq 'length')

  if (( batch_count == 0 )); then
    log "trigger: nothing to print"
    return 0
  fi

  local batch_num
  batch_num=$(next_batch_number)
  log "trigger: generating batch ${batch_num} — ${batch_count} orders [${mode_label}]"

  local picklist_file
  picklist_file=$(generate_picklist "$orders_json" "$batch_num" "$mode_label")

  if [[ -z "$picklist_file" || ! -f "$picklist_file" ]]; then
    log "trigger: generate failed"
    return 1
  fi

  print_picklist "$picklist_file"

  local order_ids
  order_ids=$(printf '%s' "$orders_json" | jq '[.[].order_id | tostring]')
  mark_printed "$order_ids"
  window_reset

  log "trigger: batch ${batch_num} complete — ${batch_count} orders"
}

case "$MODE" in

  next-25)
    # Refresh queue from BaseLinker first so we have the latest ready orders
    _fetch_and_queue_ready_orders

    local_count=$(queue_length)
    if (( local_count == 0 )); then
      log "trigger: queue is empty — no orders to print"
      exit 0
    fi

    BATCH_ORDERS=$(queue_take "$BATCH_SIZE")
    _print_batch "$BATCH_ORDERS" "manual-next-25"
    ;;

  selected)
    if [[ -z "$ARG2" ]]; then
      log "trigger: 'selected' mode requires order IDs as second argument (JSON array)"
      exit 1
    fi

    # Validate JSON
    printf '%s' "$ARG2" | jq -e '. | type == "array"' >/dev/null 2>&1 || {
      log "trigger: invalid order_ids JSON: ${ARG2}"
      exit 1
    }

    ORDER_IDS="$ARG2"
    IDS_COUNT=$(printf '%s' "$ORDER_IDS" | jq 'length')
    log "trigger: selected ${IDS_COUNT} specific orders"

    # First try to take from queue
    BATCH_ORDERS=$(queue_take_selected "$ORDER_IDS")
    FOUND_COUNT=$(printf '%s' "$BATCH_ORDERS" | jq 'length')

    # For any IDs not in queue, fetch from BaseLinker directly
    if (( FOUND_COUNT < IDS_COUNT )); then
      FOUND_IDS=$(printf '%s' "$BATCH_ORDERS" | jq '[.[].order_id | tostring]')
      MISSING_IDS=$(printf '%s' "$ORDER_IDS" | jq --argjson found "$FOUND_IDS" \
        '[.[] | tostring | select(. as $id | $found | index($id) == null)]')
      MISSING_COUNT=$(printf '%s' "$MISSING_IDS" | jq 'length')

      log "trigger: fetching ${MISSING_COUNT} orders directly from BaseLinker"

      while IFS= read -r oid; do
        [[ -z "$oid" ]] && continue
        local order_data
        order_data=$(bl_request "getOrders" \
          "$(jq -n --argjson oid "$oid" '{order_id: $oid, get_unconfirmed_orders: false}')") || continue
        local order
        order=$(printf '%s' "$order_data" | jq -c '.orders // [] | .[0] // empty')
        [[ -z "$order" ]] && continue
        BATCH_ORDERS=$(printf '%s\n[%s]' "$BATCH_ORDERS" "$order" | jq -s 'add')
      done < <(printf '%s' "$MISSING_IDS" | jq -r '.[]')
    fi

    _print_batch "$BATCH_ORDERS" "manual-selected"
    ;;

  print-label)
    # Called by pack station QR scan via /api/picklist/print-label?order_id=X
    local ORDER_ID="${ARG2:-}"
    if [[ -z "$ORDER_ID" || ! "$ORDER_ID" =~ ^[0-9]+$ ]]; then
      log "trigger: 'print-label' requires a numeric order_id as second argument"
      exit 1
    fi
    log "trigger: printing label for order ${ORDER_ID}"
    print_label_baselinker "$ORDER_ID"
    log "trigger: label job complete for order ${ORDER_ID}"
    ;;

  *)
    log "trigger: unknown mode '${MODE}' — use 'next-25', 'selected', or 'print-label'"
    exit 1
    ;;
esac

log "=== picklist-ops trigger: done ==="
