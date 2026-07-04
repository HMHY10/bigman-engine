#!/usr/bin/env bash
set -euo pipefail

# picklist-ops/run.sh — Auto-batch daemon for warehouse picklist generation
#
# Logic:
#   1. Fetch ready orders (status = PICKLIST_READY_STATUS_ID), exclude already-printed
#   2. If count >= PICKLIST_BATCH_SIZE → trigger batch immediately
#   3. If 0 < count < PICKLIST_BATCH_SIZE and timer started > PICKLIST_TIME_LIMIT_SECONDS → print partial batch
#   4. If 0 < count < PICKLIST_BATCH_SIZE and no timer yet → start timer
#   5. If count = 0 → do nothing, clear timer
#
# Runs every 5 minutes via CRONS.json.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../marketplace-lib" && pwd)"

source "${LIB_DIR}/config.sh"
source "${LIB_DIR}/cache.sh"
source "${LIB_DIR}/baselinker.sh"
source "${LIB_DIR}/alerts.sh"
source "${SCRIPT_DIR}/picklist-lib.sh"

LOCK_FILE="/tmp/picklist-ops-run.lock"

# Acquire lock — skip if already running
exec 200>"$LOCK_FILE"
flock -n 200 || { log "picklist-ops/run: another instance running, exiting"; exit 0; }

picklist_state_init

NOW=$(date +%s)
SINCE=$(( NOW - 86400 ))  # look back 24h for ready orders

log "=== picklist-ops/run: starting at $(date -u '+%Y-%m-%dT%H:%M:%SZ') ==="

# ── Fetch ready orders ─────────────────────────────────────────────────
if [[ -z "${PICKLIST_READY_STATUS_ID:-}" ]]; then
  log "picklist-ops/run: ERROR — PICKLIST_READY_STATUS_ID not set. Set in Doppler shared-services."
  exit 1
fi

ready_orders=$(picklist_get_ready_orders 0 "$SINCE")
order_count=$(printf '%s' "$ready_orders" | jq 'length')

log "picklist-ops/run: ${order_count} orders ready to pick"

# ── Decision logic ─────────────────────────────────────────────────────

if [[ "$order_count" -eq 0 ]]; then
  log "picklist-ops/run: no ready orders — clearing timer if set"
  picklist_clear_timer
  exit 0
fi

trigger_batch=false
trigger_reason=""

if (( order_count >= PICKLIST_BATCH_SIZE )); then
  trigger_batch=true
  trigger_reason="batch_size_reached (${order_count} >= ${PICKLIST_BATCH_SIZE})"
else
  # Check time limit
  timer_json=$(picklist_get_timer)
  if [[ "$timer_json" == "null" || -z "$timer_json" ]]; then
    # Start timer
    picklist_set_timer "$order_count"
    log "picklist-ops/run: timer started — ${order_count} orders waiting (threshold: ${PICKLIST_BATCH_SIZE})"
    exit 0
  fi

  timer_started=$(printf '%s' "$timer_json" | jq -r '.started_at')
  elapsed=$(( NOW - timer_started ))
  remaining=$(( PICKLIST_TIME_LIMIT_SECONDS - elapsed ))

  log "picklist-ops/run: timer running — ${order_count} orders, elapsed ${elapsed}s / ${PICKLIST_TIME_LIMIT_SECONDS}s"

  if (( elapsed >= PICKLIST_TIME_LIMIT_SECONDS )); then
    trigger_batch=true
    trigger_reason="time_limit_reached (${elapsed}s >= ${PICKLIST_TIME_LIMIT_SECONDS}s, ${order_count} orders)"
  else
    log "picklist-ops/run: waiting — ${remaining}s remaining before forced print"
    exit 0
  fi
fi

# ── Generate batch ─────────────────────────────────────────────────────

if [[ "$trigger_batch" == "true" ]]; then
  log "picklist-ops/run: triggering batch — reason: ${trigger_reason}"

  # Limit to PICKLIST_BATCH_SIZE for auto-batch
  batch_orders=$(picklist_get_ready_orders "$PICKLIST_BATCH_SIZE" "$SINCE")
  batch_order_count=$(printf '%s' "$batch_orders" | jq 'length')

  batch_id=$(picklist_batch_id "auto")
  result=$(picklist_generate "$batch_orders" "$batch_id" "auto")

  log "picklist-ops/run: batch generated — ${batch_id} (${batch_order_count} orders)"

  # Send Telegram/vault notification
  print_url="${PICKLIST_SCAN_BASE_URL:-}/picklist/print/${batch_id}?autoprint=1"

  alert_create "info" "warehouse" "Picklists/Alerts" \
    "Picklist ready: ${batch_id}" \
    "**Batch:** ${batch_id}
**Orders:** ${batch_order_count}
**Reason:** ${trigger_reason}
**Print:** [Open picklist](${print_url})

Scan QR codes at pack station after picking to trigger label printing."
fi

log "=== picklist-ops/run: complete ==="
