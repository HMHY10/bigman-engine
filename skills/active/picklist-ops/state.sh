#!/usr/bin/env bash
# picklist-ops/state.sh — State management for batch queue and print history
# Requires: config.sh sourced first

PICKLIST_STATE_DIR="${STATE_BASE}/picklist-ops"
PICKLIST_QUEUE_FILE="${PICKLIST_STATE_DIR}/batch-queue.json"
PICKLIST_WINDOW_FILE="${PICKLIST_STATE_DIR}/batch-window-start"
PICKLIST_PRINTED_FILE="${PICKLIST_STATE_DIR}/printed-order-ids.txt"
PICKLIST_LAST_DATE_FILE="${PICKLIST_STATE_DIR}/last-run-date"
PICKLIST_BATCH_COUNTER="${PICKLIST_STATE_DIR}/batch-counter"

# ── Ensure state directory exists ─────────────────────────────────────
state_init() {
  mkdir -p "$PICKLIST_STATE_DIR"
  [[ ! -f "$PICKLIST_QUEUE_FILE" ]]   && printf '[]' > "$PICKLIST_QUEUE_FILE"
  [[ ! -f "$PICKLIST_PRINTED_FILE" ]] && touch "$PICKLIST_PRINTED_FILE"
  [[ ! -f "$PICKLIST_BATCH_COUNTER" ]] && printf '0' > "$PICKLIST_BATCH_COUNTER"
}

# ── queue_get ──────────────────────────────────────────────────────────
# Print the current JSON array of queued order objects.
queue_get() {
  cat "$PICKLIST_QUEUE_FILE" 2>/dev/null || printf '[]'
}

# ── queue_set <json_array> ─────────────────────────────────────────────
# Replace the queue with a new JSON array.
queue_set() {
  printf '%s' "$1" > "$PICKLIST_QUEUE_FILE"
}

# ── queue_add_orders <orders_json_array> ──────────────────────────────
# Merge new orders into the queue, deduplicating by order_id.
# Orders already marked as printed are silently dropped.
queue_add_orders() {
  local new_orders="$1"
  local current
  current=$(queue_get)

  local merged
  merged=$(printf '%s\n%s' "$current" "$new_orders" | jq -s '
    add
    | unique_by(.order_id)
    | sort_by(.date_add // 0)
  ')
  queue_set "$merged"
  log "state: queue updated — $(printf '%s' "$merged" | jq 'length') orders"
}

# ── queue_take <n> ────────────────────────────────────────────────────
# Print the first N orders from the queue as a JSON array and remove them.
# If n <= 0, take all.
queue_take() {
  local n="$1"
  local current
  current=$(queue_get)

  local taken remaining
  if (( n <= 0 )); then
    taken="$current"
    remaining="[]"
  else
    taken=$(printf '%s' "$current" | jq --argjson n "$n" '.[:$n]')
    remaining=$(printf '%s' "$current" | jq --argjson n "$n" '.[$n:]')
  fi

  queue_set "$remaining"
  printf '%s' "$taken"
}

# ── queue_take_selected <order_ids_json_array> ────────────────────────
# Print orders matching the given IDs and remove them from queue.
queue_take_selected() {
  local ids="$1"
  local current
  current=$(queue_get)

  local taken remaining
  taken=$(printf '%s' "$current" | jq --argjson ids "$ids" \
    '[.[] | select(.order_id as $oid | $ids | map(tostring) | index(($oid | tostring)) != null)]')
  remaining=$(printf '%s' "$current" | jq --argjson ids "$ids" \
    '[.[] | select(.order_id as $oid | $ids | map(tostring) | index(($oid | tostring)) == null)]')

  queue_set "$remaining"
  printf '%s' "$taken"
}

# ── queue_length ───────────────────────────────────────────────────────
queue_length() {
  queue_get | jq 'length'
}

# ── window_start ───────────────────────────────────────────────────────
# Set batch window start time to now if not already set.
window_start() {
  [[ ! -f "$PICKLIST_WINDOW_FILE" ]] && date +%s > "$PICKLIST_WINDOW_FILE"
}

# ── window_reset ───────────────────────────────────────────────────────
# Clear batch window (call after printing a batch).
window_reset() {
  rm -f "$PICKLIST_WINDOW_FILE"
}

# ── window_age_seconds ─────────────────────────────────────────────────
# Print seconds elapsed since batch window started, or 0 if no window.
window_age_seconds() {
  [[ ! -f "$PICKLIST_WINDOW_FILE" ]] && { echo 0; return; }
  local start now
  start=$(cat "$PICKLIST_WINDOW_FILE")
  now=$(date +%s)
  echo $(( now - start ))
}

# ── is_morning_batch ──────────────────────────────────────────────────
# Return 0 if this is the first run since midnight (morning batch mode).
is_morning_batch() {
  local today
  today=$(date '+%Y-%m-%d')
  local last_date
  last_date=$(cat "$PICKLIST_LAST_DATE_FILE" 2>/dev/null || echo "")
  [[ "$last_date" != "$today" ]]
}

# ── mark_day_started ─────────────────────────────────────────────────
# Record today's date so morning batch only fires once per day.
mark_day_started() {
  date '+%Y-%m-%d' > "$PICKLIST_LAST_DATE_FILE"
}

# ── mark_printed <order_ids_json_array> ───────────────────────────────
# Record order IDs as printed to avoid reprints.
mark_printed() {
  local ids="$1"
  printf '%s' "$ids" | jq -r '.[]' >> "$PICKLIST_PRINTED_FILE"
  # Deduplicate the file
  sort -u "$PICKLIST_PRINTED_FILE" -o "$PICKLIST_PRINTED_FILE"
  log "state: marked $(printf '%s' "$ids" | jq 'length') orders as printed"
}

# ── filter_unprinted <orders_json_array> ─────────────────────────────
# Print only orders that have not been printed before.
filter_unprinted() {
  local orders="$1"
  if [[ ! -s "$PICKLIST_PRINTED_FILE" ]]; then
    printf '%s' "$orders"
    return
  fi

  local printed_json
  printed_json=$(awk '{printf "\"%s\",", $0}' "$PICKLIST_PRINTED_FILE" | sed 's/,$//')
  printed_json="[${printed_json}]"

  printf '%s' "$orders" | jq --argjson printed "$printed_json" \
    '[.[] | select(.order_id as $oid | $printed | map(tostring) | index(($oid | tostring)) == null)]'
}

# ── next_batch_number ─────────────────────────────────────────────────
# Return the next batch number and increment the counter.
next_batch_number() {
  local n
  n=$(cat "$PICKLIST_BATCH_COUNTER" 2>/dev/null || echo 0)
  n=$((n + 1))
  printf '%d' "$n" > "$PICKLIST_BATCH_COUNTER"
  echo "$n"
}
