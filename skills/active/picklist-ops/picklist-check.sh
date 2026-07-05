#!/usr/bin/env bash
set -euo pipefail

# picklist-ops/picklist-check.sh — Auto-batch cron runner (every 5 minutes)
#
# Decision logic:
#   1. Count unprinted orders with PICKLIST_READY_STATUS_ID
#   2. If >= PICKLIST_BATCH_SIZE (25):  generate a batch of 25 immediately
#   3. Else if batch window has expired AND count > 0:  print whatever is available (fallback)
#   4. Else if count > 0 AND no window running:  start the 60-minute countdown window
#   5. If count == 0:  clear any stale window
#
# Runs as: doppler run -p shared-services -c prd -- ./picklist-check.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../marketplace-lib" && pwd)"

source "${LIB_DIR}/config.sh"
source "${LIB_DIR}/cache.sh"
source "${LIB_DIR}/baselinker.sh"
source "${LIB_DIR}/alerts.sh"
source "${SCRIPT_DIR}/picklist-lib.sh"

picklist_init

if [[ -z "${PICKLIST_READY_STATUS_ID:-}" ]]; then
  log "picklist-check: PICKLIST_READY_STATUS_ID not set — skipping"
  exit 0
fi

# ── Count unprinted ready orders ──────────────────────────────────────
SINCE=$(since_epoch "$PICKLIST_SINCE_HOURS")
log "picklist-check: fetching ready orders..."

ALL_READY=$(bl_get_orders "$SINCE" "$PICKLIST_READY_STATUS_ID") || {
  log "picklist-check: BaseLinker fetch failed — skipping this run"
  exit 0
}

TOTAL_READY=$(printf '%s' "$ALL_READY" | jq 'length')

PRINTED=$(printed_orders_load)
UNPRINTED=$(printf '%s' "$ALL_READY" | jq \
  --argjson printed "$PRINTED" \
  '[.[] | select(.order_id as $id | $printed | index($id) == null)] | length')

log "picklist-check: ${UNPRINTED} unprinted ready orders (${TOTAL_READY} total ready)"

# ── Decision tree ─────────────────────────────────────────────────────

if (( UNPRINTED == 0 )); then
  batch_window_clear
  log "picklist-check: no orders — window cleared"
  exit 0
fi

if (( UNPRINTED >= PICKLIST_BATCH_SIZE )); then
  log "picklist-check: threshold reached (${UNPRINTED} >= ${PICKLIST_BATCH_SIZE}) — generating batch of ${PICKLIST_BATCH_SIZE}"
  exec "${SCRIPT_DIR}/picklist-generate.sh" batch "${PICKLIST_BATCH_SIZE}"
fi

# Under threshold — check batch window
WINDOW_EPOCH=$(batch_window_start_epoch)
ELAPSED=$(batch_window_minutes_elapsed)

if (( WINDOW_EPOCH == 0 )); then
  log "picklist-check: ${UNPRINTED} orders accumulating — starting ${PICKLIST_BATCH_WINDOW_MINUTES}-min window"
  batch_window_set
  exit 0
fi

if batch_window_expired; then
  log "picklist-check: window expired after ${ELAPSED} min with ${UNPRINTED} orders — printing fallback batch"
  exec "${SCRIPT_DIR}/picklist-generate.sh" batch "${UNPRINTED}"
fi

log "picklist-check: ${UNPRINTED} orders, window ${ELAPSED}/${PICKLIST_BATCH_WINDOW_MINUTES} min — waiting"
