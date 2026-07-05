#!/usr/bin/env bash
# picklist-ops/state.sh — State management for picklist queue and picklist records
# Requires: config.sh sourced first (for log function)
#
# State layout under $PICKLIST_STATE_DIR:
#   queue.json          — array of order objects waiting to be assigned to a picklist
#   last-fetch-ts       — epoch of last BaseLinker order fetch
#   last-batch-ts       — epoch of last batch print (for daytime time-limit fallback)
#   counter             — incrementing integer for PL numbering within a day
#   picklists/          — one JSON file per picklist: PL-YYYYMMDD-NNN.json

PICKLIST_STATE_DIR="${STATE_BASE}/picklist-ops"
PICKLIST_QUEUE="${PICKLIST_STATE_DIR}/queue.json"
PICKLIST_LAST_FETCH="${PICKLIST_STATE_DIR}/last-fetch-ts"
PICKLIST_LAST_BATCH="${PICKLIST_STATE_DIR}/last-batch-ts"
PICKLIST_COUNTER="${PICKLIST_STATE_DIR}/counter"
PICKLIST_LISTS_DIR="${PICKLIST_STATE_DIR}/picklists"
PICKLIST_HTML_DIR="${PICKLIST_STATE_DIR}/html"

# ── state_init ────────────────────────────────────────────────────────
# Ensure all state directories and files exist.
state_init() {
  mkdir -p "$PICKLIST_STATE_DIR" "$PICKLIST_LISTS_DIR" "$PICKLIST_HTML_DIR"
  [[ -f "$PICKLIST_QUEUE" ]] || printf '[]' > "$PICKLIST_QUEUE"
  [[ -f "$PICKLIST_LAST_FETCH" ]] || printf '0' > "$PICKLIST_LAST_FETCH"
  [[ -f "$PICKLIST_LAST_BATCH" ]] || printf '0' > "$PICKLIST_LAST_BATCH"
  [[ -f "$PICKLIST_COUNTER" ]] || printf '0' > "$PICKLIST_COUNTER"
  log "state_init: directories ready at ${PICKLIST_STATE_DIR}"
}

# ── state_get_last_fetch ──────────────────────────────────────────────
# Print epoch of last order fetch (0 if never run).
state_get_last_fetch() {
  cat "$PICKLIST_LAST_FETCH" 2>/dev/null || printf '0'
}

# ── state_set_last_fetch <epoch> ──────────────────────────────────────
state_set_last_fetch() {
  printf '%s' "$1" > "$PICKLIST_LAST_FETCH"
}

# ── state_get_last_batch ──────────────────────────────────────────────
# Print epoch of last batch print (0 if never).
state_get_last_batch() {
  cat "$PICKLIST_LAST_BATCH" 2>/dev/null || printf '0'
}

# ── state_set_last_batch ──────────────────────────────────────────────
state_set_last_batch() {
  printf '%s' "$(date +%s)" > "$PICKLIST_LAST_BATCH"
}

# ── state_queue_count ─────────────────────────────────────────────────
# Print number of orders currently in the queue.
state_queue_count() {
  jq 'length' "$PICKLIST_QUEUE" 2>/dev/null || printf '0'
}

# ── state_enqueue_orders <orders_json_array> ──────────────────────────
# Add new orders to queue (skips any already queued by order_id).
state_enqueue_orders() {
  local new_orders="$1"
  local added=0

  # Load existing queue IDs for dedup check
  local existing_ids
  existing_ids=$(jq '[.[].order_id]' "$PICKLIST_QUEUE")

  # Merge: add only orders whose order_id is not already in queue
  local merged
  merged=$(jq -n \
    --argjson queue "$(cat "$PICKLIST_QUEUE")" \
    --argjson new "$new_orders" \
    --argjson existing "$existing_ids" \
    '$queue + [$new[] | select(.order_id as $id | $existing | index($id) == null)]')

  local before after
  before=$(jq 'length' "$PICKLIST_QUEUE")
  printf '%s' "$merged" > "$PICKLIST_QUEUE"
  after=$(jq 'length' "$PICKLIST_QUEUE")
  added=$((after - before))

  log "state_enqueue_orders: added ${added} new orders (queue depth: ${after})"
  printf '%d' "$added"
}

# ── state_dequeue_batch <count> ───────────────────────────────────────
# Remove and return the first <count> orders from the queue (FIFO).
# Prints a JSON array of the dequeued orders to stdout.
state_dequeue_batch() {
  local count="$1"
  local batch

  batch=$(jq --argjson n "$count" '.[:$n]' "$PICKLIST_QUEUE")

  # Remove the dequeued orders from queue
  local remaining
  remaining=$(jq --argjson n "$count" '.[$n:]' "$PICKLIST_QUEUE")
  printf '%s' "$remaining" > "$PICKLIST_QUEUE"

  local batch_size
  batch_size=$(printf '%s' "$batch" | jq 'length')
  log "state_dequeue_batch: dequeued ${batch_size} orders (${count} requested)"

  printf '%s' "$batch"
}

# ── state_dequeue_selected <order_ids_csv> ────────────────────────────
# Remove specific orders from queue by order_id (comma-separated).
# Prints JSON array of matched orders to stdout.
state_dequeue_selected() {
  local ids_csv="$1"
  # Convert CSV to JSON array of numbers
  local ids_json
  ids_json=$(printf '%s' "$ids_csv" | tr ',' '\n' | jq -R 'tonumber' | jq -s '.')

  local matched remaining
  matched=$(jq --argjson ids "$ids_json" \
    '[.[] | select(.order_id as $id | $ids | index($id) != null)]' \
    "$PICKLIST_QUEUE")
  remaining=$(jq --argjson ids "$ids_json" \
    '[.[] | select(.order_id as $id | $ids | index($id) == null)]' \
    "$PICKLIST_QUEUE")

  printf '%s' "$remaining" > "$PICKLIST_QUEUE"

  local matched_count
  matched_count=$(printf '%s' "$matched" | jq 'length')
  log "state_dequeue_selected: dequeued ${matched_count} orders by ID"

  printf '%s' "$matched"
}

# ── state_next_picklist_id ────────────────────────────────────────────
# Generate and return the next picklist ID (e.g., PL-20260705-003).
# Increments counter atomically.
state_next_picklist_id() {
  local date_str
  date_str=$(date '+%Y%m%d')

  # Reset counter if it's a new day (detect via stored date prefix in counter file)
  local stored_date
  stored_date=$(cat "${PICKLIST_COUNTER}.date" 2>/dev/null || printf '')
  if [[ "$stored_date" != "$date_str" ]]; then
    printf '0' > "$PICKLIST_COUNTER"
    printf '%s' "$date_str" > "${PICKLIST_COUNTER}.date"
  fi

  local n
  n=$(cat "$PICKLIST_COUNTER" 2>/dev/null || printf '0')
  n=$((n + 1))
  printf '%d' "$n" > "$PICKLIST_COUNTER"

  printf 'PL-%s-%03d' "$date_str" "$n"
}

# ── state_save_picklist <picklist_id> <type> <orders_json> ───────────
# Persist picklist metadata to state. Returns the saved file path.
state_save_picklist() {
  local pl_id="$1" type="$2" orders_json="$3"
  local file="${PICKLIST_LISTS_DIR}/${pl_id}.json"

  local order_count
  order_count=$(printf '%s' "$orders_json" | jq 'length')

  jq -n \
    --arg id "$pl_id" \
    --arg type "$type" \
    --arg created "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --argjson orders "$orders_json" \
    --argjson count "$order_count" \
    '{
      picklist_id: $id,
      type: $type,
      created: $created,
      status: "pending",
      order_count: $count,
      orders: $orders
    }' > "$file"

  log "state_save_picklist: saved ${pl_id} (${order_count} orders, type: ${type})"
  printf '%s' "$file"
}

# ── state_mark_printed <picklist_id> <html_path> ─────────────────────
# Update picklist status to 'printed'.
state_mark_printed() {
  local pl_id="$1" html_path="${2:-}"
  local file="${PICKLIST_LISTS_DIR}/${pl_id}.json"

  [[ ! -f "$file" ]] && { log "state_mark_printed: ${pl_id} not found"; return 1; }

  local updated
  updated=$(jq \
    --arg printed "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg html "$html_path" \
    '.status = "printed" | .printed_at = $printed | .html_path = $html' \
    "$file")
  printf '%s' "$updated" > "$file"
  log "state_mark_printed: ${pl_id} marked printed"
}

# ── state_mark_completed <picklist_id> ───────────────────────────────
# Update picklist status to 'completed' (labels printed, picker done).
state_mark_completed() {
  local pl_id="$1"
  local file="${PICKLIST_LISTS_DIR}/${pl_id}.json"

  [[ ! -f "$file" ]] && { log "state_mark_completed: ${pl_id} not found"; return 1; }

  local updated
  updated=$(jq \
    --arg completed "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '.status = "completed" | .completed_at = $completed' \
    "$file")
  printf '%s' "$updated" > "$file"
  log "state_mark_completed: ${pl_id} marked completed"
}

# ── state_get_picklist <picklist_id> ─────────────────────────────────
# Print picklist JSON to stdout.
state_get_picklist() {
  local pl_id="$1"
  local file="${PICKLIST_LISTS_DIR}/${pl_id}.json"

  if [[ ! -f "$file" ]]; then
    log "state_get_picklist: ${pl_id} not found"
    return 1
  fi
  cat "$file"
}

# ── state_get_order_ids_for_picklist <picklist_id> ───────────────────
# Print JSON array of order_ids in a picklist.
state_get_order_ids_for_picklist() {
  local pl_id="$1"
  local pl
  pl=$(state_get_picklist "$pl_id") || return 1
  printf '%s' "$pl" | jq '[.orders[].order_id]'
}
