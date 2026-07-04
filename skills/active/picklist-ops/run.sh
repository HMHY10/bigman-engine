#!/usr/bin/env bash
set -euo pipefail
# picklist-ops/run.sh — Polling script for auto-batch picklist generation
#
# Modes:
#   morning  — first run of the day; prints ALL overnight ready orders (no cap)
#   auto-25  — queue has reached PICKLIST_BATCH_SIZE (default 25)
#   timeout  — queue has waited > PICKLIST_TIMEOUT_MINS (default 60) with at least 1 order
#   idle     — not enough orders and not timed out; just update queue and exit
#
# Runs: every 5 minutes via picklist-poll cron
# Run as: doppler run -p shared-services -c prd -- ./run.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../marketplace-lib" && pwd)"

source "${LIB_DIR}/config.sh"
source "${LIB_DIR}/cache.sh"
source "${LIB_DIR}/baselinker.sh"
source "${SCRIPT_DIR}/state.sh"
source "${SCRIPT_DIR}/generate.sh"
source "${SCRIPT_DIR}/print.sh"

# ── Config ────────────────────────────────────────────────────────────
BATCH_SIZE="${PICKLIST_BATCH_SIZE:-25}"
TIMEOUT_SECS=$(( ${PICKLIST_TIMEOUT_MINS:-60} * 60 ))
PICK_STATUS_ID="${BL_PICK_STATUS_ID:-}"

if [[ -z "$PICK_STATUS_ID" ]]; then
  log "run: BL_PICK_STATUS_ID not set — cannot fetch ready orders"
  exit 1
fi

log "=== picklist-ops: run starting ==="
state_init

# ── 1. Fetch ready orders from BaseLinker ────────────────────────────
log "Fetching ready orders (status ${PICK_STATUS_ID})..."
SINCE=$(( $(date +%s) - 86400 * 30 ))  # Look back 30 days to catch any backlog

READY_ORDERS=$(bl_get_orders "$SINCE" "$PICK_STATUS_ID" 2>/dev/null || printf '[]')
[[ -z "$READY_ORDERS" ]] && READY_ORDERS='[]'

READY_COUNT=$(printf '%s' "$READY_ORDERS" | jq 'length')
log "Ready orders from BaseLinker: ${READY_COUNT}"

# ── 2. Filter out already-printed orders ─────────────────────────────
UNPRINTED=$(filter_unprinted "$READY_ORDERS")
UNPRINTED_COUNT=$(printf '%s' "$UNPRINTED" | jq 'length')
log "Unprinted ready orders: ${UNPRINTED_COUNT}"

# ── 3. Update the queue with any new orders ──────────────────────────
if (( UNPRINTED_COUNT > 0 )); then
  queue_add_orders "$UNPRINTED"
  window_start  # Start/keep window timer running
fi

QUEUE_LEN=$(queue_length)
log "Queue depth: ${QUEUE_LEN}"

if (( QUEUE_LEN == 0 )); then
  log "run: queue empty — nothing to print"
  log "=== picklist-ops: run complete (idle) ==="
  exit 0
fi

# ── 4. Determine firing mode ─────────────────────────────────────────
WINDOW_AGE=$(window_age_seconds)
FIRE_MODE=""

if is_morning_batch; then
  # First run since midnight — print everything regardless of count
  FIRE_MODE="morning"
  log "run: MORNING BATCH mode — ${QUEUE_LEN} orders queued overnight"
elif (( QUEUE_LEN >= BATCH_SIZE )); then
  FIRE_MODE="auto-25"
  log "run: AUTO-BATCH mode — ${QUEUE_LEN} orders >= threshold ${BATCH_SIZE}"
elif (( WINDOW_AGE >= TIMEOUT_SECS )); then
  FIRE_MODE="timeout"
  log "run: TIMEOUT mode — ${WINDOW_AGE}s elapsed (>${TIMEOUT_SECS}s), printing ${QUEUE_LEN} orders"
else
  log "run: idle — ${QUEUE_LEN}/${BATCH_SIZE} orders, window age ${WINDOW_AGE}s/${TIMEOUT_SECS}s"
  log "=== picklist-ops: run complete (waiting) ==="
  exit 0
fi

# ── 5. Determine how many orders to take ─────────────────────────────
if [[ "$FIRE_MODE" == "morning" ]]; then
  TAKE_COUNT=0  # 0 = take all
elif [[ "$FIRE_MODE" == "auto-25" ]]; then
  TAKE_COUNT="$BATCH_SIZE"
else
  TAKE_COUNT=0  # timeout: print all waiting
fi

BATCH_NUM=$(next_batch_number)
BATCH_ORDERS=$(queue_take "$TAKE_COUNT")
BATCH_COUNT=$(printf '%s' "$BATCH_ORDERS" | jq 'length')

log "run: printing batch ${BATCH_NUM} — ${BATCH_COUNT} orders [${FIRE_MODE}]"

if (( BATCH_COUNT == 0 )); then
  log "run: empty batch after take — nothing to print"
  log "=== picklist-ops: run complete (empty batch) ==="
  exit 0
fi

# ── 6. Mark day started (morning batch only fires once) ──────────────
[[ "$FIRE_MODE" == "morning" ]] && mark_day_started

# ── 7. Generate picklist HTML ─────────────────────────────────────────
log "Generating picklist HTML..."
PICKLIST_FILE=$(generate_picklist "$BATCH_ORDERS" "$BATCH_NUM" "$FIRE_MODE")

if [[ -z "$PICKLIST_FILE" || ! -f "$PICKLIST_FILE" ]]; then
  log "run: generate_picklist failed"
  exit 1
fi
log "Picklist file: ${PICKLIST_FILE}"

# ── 8. Print picklist ─────────────────────────────────────────────────
log "Sending to printer..."
print_picklist "$PICKLIST_FILE"

# ── 9. Mark orders as printed and reset window ────────────────────────
BATCH_ORDER_IDS=$(printf '%s' "$BATCH_ORDERS" | jq '[.[].order_id | tostring]')
mark_printed "$BATCH_ORDER_IDS"
window_reset

# ── 10. Vault log ─────────────────────────────────────────────────────
if [[ -n "${OBSIDIAN_API_KEY:-}" && -n "${VAULT_URL:-}" ]]; then
  DATE_STR=$(date '+%Y-%m-%d')
  TS_STR=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  ORDER_IDS_LIST=$(printf '%s' "$BATCH_ORDERS" | jq -r '.[].order_id' | awk '{printf "- #%s\n", $1}')

  VAULT_CONTENT="---
source: picklist-ops
type: picklist-batch
batch: ${BATCH_NUM}
mode: ${FIRE_MODE}
date: ${DATE_STR}
orders: ${BATCH_COUNT}
---

# Picklist Batch ${BATCH_NUM} — ${DATE_STR}

**Mode:** ${FIRE_MODE}
**Orders:** ${BATCH_COUNT}
**Generated:** ${TS_STR}

## Orders Included

${ORDER_IDS_LIST}
"
  VAULT_PATH="07-Marketplace/Picklists/${DATE_STR}-batch${BATCH_NUM}.md"
  curl -sS -o /dev/null -w '' \
    -X PUT "${VAULT_URL}/vault/${VAULT_PATH}" \
    -H "Authorization: Bearer ${OBSIDIAN_API_KEY}" \
    -H "Content-Type: text/markdown" \
    -d "$VAULT_CONTENT" || log "vault log: write failed (non-fatal)"

  log "run: vault log written to ${VAULT_PATH}"
fi

log "=== picklist-ops: batch ${BATCH_NUM} complete [${FIRE_MODE}] — ${BATCH_COUNT} orders printed ==="
