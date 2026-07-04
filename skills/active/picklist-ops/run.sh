#!/usr/bin/env bash
set -euo pipefail

# picklist-ops/run.sh — Warehouse picklist automation for ArryBarry
# Runs as: doppler run -p shared-services -c prd -- ./run.sh [MODE] [ARGS]
#
# Modes:
#   --auto                           Poll: batch if >=25 ready, or time-limit hit
#   --morning                        Print all overnight orders (no cap)
#   --manual-next25                  Print next batch of up to 25 orders
#   --manual-selected ORDER_ID,...   Print specific comma-separated order IDs

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../marketplace-lib" && pwd)"

source "${LIB_DIR}/config.sh"
source "${LIB_DIR}/cache.sh"
source "${LIB_DIR}/baselinker.sh"
source "${LIB_DIR}/alerts.sh"

# ── Configuration ────────────────────────────────────────────────────────
BATCH_SIZE="${PICKLIST_BATCH_SIZE:-25}"
TIME_LIMIT="${PICKLIST_TIME_LIMIT_SECS:-3600}"
READY_STATUS="${PICKLIST_READY_STATUS_ID:-}"
PICKING_STATUS="${PICKLIST_PICKING_STATUS_ID:-}"
OUTPUT_DIR="/opt/bigman-engine/picklists"
STATE_DIR="${STATE_BASE}/picklist-ops"
# Look back 30 days — any "ready" order older than that is an anomaly
LOOKBACK_SECS=$(( 30 * 86400 ))

mkdir -p "$OUTPUT_DIR" "$STATE_DIR"

MODE="${1:---auto}"
SELECTED_IDS="${2:-}"

# ── State helpers ────────────────────────────────────────────────────────
state_read() {
  local key="$1"
  cat "${STATE_DIR}/${key}" 2>/dev/null || echo ""
}
state_write() {
  local key="$1" val="$2"
  printf '%s' "$val" > "${STATE_DIR}/${key}"
}

# ── Validate ─────────────────────────────────────────────────────────────
if [[ -z "$READY_STATUS" ]]; then
  log "picklist-ops: PICKLIST_READY_STATUS_ID is not set — cannot run"
  log "picklist-ops: Set this to the BaseLinker status_id that means 'ready to pick'"
  exit 1
fi

# ── Fetch ready orders ────────────────────────────────────────────────────
# Returns a JSON array of orders with the configured ready status
fetch_ready_orders() {
  local since=$(( $(date +%s) - LOOKBACK_SECS ))
  bl_get_orders "$since" "$READY_STATUS" || echo "[]"
}

# ── Mark orders as picking ────────────────────────────────────────────────
# Sets PICKLIST_PICKING_STATUS_ID on each order to prevent double-batching.
# Only runs if PICKING_STATUS is configured.
mark_orders_picking() {
  local orders="$1"
  [[ -z "$PICKING_STATUS" ]] && return 0

  local marked=0 failed=0
  while IFS= read -r order_id; do
    [[ -z "$order_id" ]] && continue
    local params
    params=$(jq -n --argjson oid "$order_id" --argjson sid "$PICKING_STATUS" \
      '{order_id: $oid, status_id: $sid}')
    if bl_request "setOrderStatus" "$params" > /dev/null 2>&1; then
      marked=$(( marked + 1 ))
    else
      failed=$(( failed + 1 ))
      log "picklist-ops: failed to mark order ${order_id} as picking"
    fi
  done < <(printf '%s' "$orders" | jq -r '.[].order_id')

  log "picklist-ops: marked ${marked} orders as picking, ${failed} failed"
}

# ── Generate batch ────────────────────────────────────────────────────────
# Takes a JSON array of orders and a batch type label.
# Calls generate-picklist.py to produce the HTML, then updates state.
generate_batch() {
  local orders="$1"
  local batch_type="$2"

  local order_count
  order_count=$(printf '%s' "$orders" | jq 'length')

  # Increment batch counter
  local batch_num
  batch_num=$(state_read "batch-counter")
  [[ -z "$batch_num" || ! "$batch_num" =~ ^[0-9]+$ ]] && batch_num=0
  batch_num=$(( batch_num + 1 ))
  state_write "batch-counter" "$batch_num"

  log "picklist-ops: generating batch #${batch_num} — ${order_count} orders (${batch_type})"

  # Call the Python generator
  local html_path
  html_path=$(PICKLIST_ORDERS="$orders" \
    PICKLIST_BATCH_ID="$batch_num" \
    PICKLIST_BATCH_TYPE="$batch_type" \
    PICKLIST_HOST="${PICKLIST_HOST:-http://localhost:3000}" \
    PICKLIST_OUTPUT_DIR="$OUTPUT_DIR" \
    PICKLIST_PRINT_CMD="${PICKLIST_PRINT_CMD:-}" \
    VAULT_URL="${VAULT_URL}" \
    OBSIDIAN_API_KEY="${OBSIDIAN_API_KEY:-}" \
    python3 "${SCRIPT_DIR}/generate-picklist.py")

  if [[ -n "$html_path" && -f "$html_path" ]]; then
    log "picklist-ops: picklist saved — ${html_path}"
  else
    log "picklist-ops: WARNING — generate-picklist.py returned no path"
  fi

  # Mark orders in BaseLinker to prevent double-batching
  mark_orders_picking "$orders"

  # Update state
  state_write "last-batch-time" "$(date +%s)"
  state_write "queue-first-seen" ""  # reset timer for next batch

  log "picklist-ops: batch #${batch_num} complete"
}

# ════════════════════════════════════════════════════════════════════════════
# MODE: --auto (runs every 5 minutes via cron)
# Logic: if queue >= BATCH_SIZE → batch; if queue older than TIME_LIMIT → batch
# ════════════════════════════════════════════════════════════════════════════
if [[ "$MODE" == "--auto" ]]; then
  log "picklist-ops [auto]: checking ready queue"

  READY_ORDERS=$(fetch_ready_orders)
  READY_COUNT=$(printf '%s' "$READY_ORDERS" | jq 'length')
  NOW=$(date +%s)

  if (( READY_COUNT == 0 )); then
    state_write "queue-first-seen" ""
    log "picklist-ops [auto]: queue empty — nothing to do"
    exit 0
  fi

  log "picklist-ops [auto]: ${READY_COUNT} order(s) in ready status"

  # Track when the queue was first non-empty
  FIRST_SEEN=$(state_read "queue-first-seen")
  if [[ -z "$FIRST_SEEN" || ! "$FIRST_SEEN" =~ ^[0-9]+$ ]]; then
    state_write "queue-first-seen" "$NOW"
    FIRST_SEEN="$NOW"
    log "picklist-ops [auto]: queue timer started"
  fi

  QUEUE_AGE=$(( NOW - FIRST_SEEN ))
  REMAINING=$(( TIME_LIMIT - QUEUE_AGE ))

  if (( READY_COUNT >= BATCH_SIZE )); then
    log "picklist-ops [auto]: threshold reached (${READY_COUNT}/${BATCH_SIZE}) — generating batch"
    BATCH_ORDERS=$(printf '%s' "$READY_ORDERS" | jq --argjson n "$BATCH_SIZE" '.[:$n]')
    generate_batch "$BATCH_ORDERS" "auto"

  elif (( QUEUE_AGE >= TIME_LIMIT )); then
    log "picklist-ops [auto]: time limit reached (${QUEUE_AGE}s, ${READY_COUNT} orders) — generating batch"
    generate_batch "$READY_ORDERS" "time-limit"

  else
    log "picklist-ops [auto]: waiting — ${READY_COUNT}/${BATCH_SIZE} orders, ${REMAINING}s until time-limit"
  fi

# ════════════════════════════════════════════════════════════════════════════
# MODE: --morning (runs at 07:30 via cron)
# Prints ALL orders in ready status — no cap — then marks date to avoid re-run
# ════════════════════════════════════════════════════════════════════════════
elif [[ "$MODE" == "--morning" ]]; then
  TODAY=$(date '+%Y-%m-%d')
  LAST_MORNING=$(state_read "morning-batch-date")

  if [[ "$LAST_MORNING" == "$TODAY" ]]; then
    log "picklist-ops [morning]: already run today (${TODAY}), skipping"
    exit 0
  fi

  log "picklist-ops [morning]: starting overnight order sweep"
  READY_ORDERS=$(fetch_ready_orders)
  READY_COUNT=$(printf '%s' "$READY_ORDERS" | jq 'length')

  if (( READY_COUNT == 0 )); then
    log "picklist-ops [morning]: no orders in ready status — nothing to print"
    state_write "morning-batch-date" "$TODAY"
    exit 0
  fi

  log "picklist-ops [morning]: ${READY_COUNT} overnight orders — generating full batch"
  generate_batch "$READY_ORDERS" "morning"
  state_write "morning-batch-date" "$TODAY"
  # Reset auto queue timer since we just cleared it
  state_write "queue-first-seen" ""

# ════════════════════════════════════════════════════════════════════════════
# MODE: --manual-next25 (webhook or manual trigger)
# Prints next batch of up to BATCH_SIZE orders
# ════════════════════════════════════════════════════════════════════════════
elif [[ "$MODE" == "--manual-next25" ]]; then
  log "picklist-ops [manual-next25]: triggered"
  READY_ORDERS=$(fetch_ready_orders)
  READY_COUNT=$(printf '%s' "$READY_ORDERS" | jq 'length')

  if (( READY_COUNT == 0 )); then
    log "picklist-ops [manual-next25]: no orders ready — nothing to print"
    exit 0
  fi

  BATCH_ORDERS=$(printf '%s' "$READY_ORDERS" | jq --argjson n "$BATCH_SIZE" '.[:$n]')
  BATCH_COUNT=$(printf '%s' "$BATCH_ORDERS" | jq 'length')
  log "picklist-ops [manual-next25]: printing ${BATCH_COUNT} of ${READY_COUNT} ready orders"
  generate_batch "$BATCH_ORDERS" "manual"

# ════════════════════════════════════════════════════════════════════════════
# MODE: --manual-selected ORDER_ID,ORDER_ID,...
# Prints a picklist for a specific set of order IDs
# ════════════════════════════════════════════════════════════════════════════
elif [[ "$MODE" == "--manual-selected" ]]; then
  if [[ -z "$SELECTED_IDS" ]]; then
    log "picklist-ops [manual-selected]: no order IDs provided"
    log "Usage: run.sh --manual-selected ORDER_ID1,ORDER_ID2,..."
    exit 1
  fi

  # Sanitise: keep only digits and commas
  SAFE_IDS=$(printf '%s' "$SELECTED_IDS" | tr -cd '0-9,')
  if [[ -z "$SAFE_IDS" ]]; then
    log "picklist-ops [manual-selected]: no valid order IDs after sanitisation"
    exit 1
  fi

  log "picklist-ops [manual-selected]: fetching orders: ${SAFE_IDS}"

  SELECTED_ORDERS="[]"
  while IFS= read -r oid; do
    [[ -z "$oid" ]] && continue
    ORDER_PARAMS=$(jq -n --argjson id "$oid" '{order_id: $id}')
    ORDER_RAW=$(bl_request "getOrders" "$ORDER_PARAMS" 2>/dev/null || echo '{}')
    ORDER_JSON=$(printf '%s' "$ORDER_RAW" | jq -c '.orders[0] // empty')
    [[ -z "$ORDER_JSON" ]] && { log "picklist-ops: order ${oid} not found"; continue; }
    SELECTED_ORDERS=$(printf '%s\n[%s]' "$SELECTED_ORDERS" "$ORDER_JSON" | jq -s 'add')
  done < <(printf '%s' "$SAFE_IDS" | tr ',' '\n')

  SEL_COUNT=$(printf '%s' "$SELECTED_ORDERS" | jq 'length')
  if (( SEL_COUNT == 0 )); then
    log "picklist-ops [manual-selected]: no orders found for IDs: ${SAFE_IDS}"
    exit 1
  fi

  log "picklist-ops [manual-selected]: printing ${SEL_COUNT} selected orders"
  generate_batch "$SELECTED_ORDERS" "manual-selected"

else
  log "picklist-ops: unknown mode '${MODE}'"
  log "Usage: run.sh [--auto|--morning|--manual-next25|--manual-selected ORDER_IDS]"
  exit 1
fi

log "picklist-ops: done"
