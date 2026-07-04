#!/usr/bin/env bash
set -euo pipefail

# picklist-ops/morning-batch.sh — Morning batch: all overnight orders, no cap, grouped by SKU
#
# Runs at 07:00 daily via CRONS.json.
# Fetches ALL ready orders since the previous working day's close (default: 13h back = ~6 PM yesterday).
# Generates one combined picklist covering the full overnight queue.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../marketplace-lib" && pwd)"

source "${LIB_DIR}/config.sh"
source "${LIB_DIR}/cache.sh"
source "${LIB_DIR}/baselinker.sh"
source "${LIB_DIR}/alerts.sh"
source "${SCRIPT_DIR}/picklist-lib.sh"

LOCK_FILE="/tmp/picklist-ops-morning.lock"

exec 200>"$LOCK_FILE"
flock -n 200 || { log "picklist-ops/morning: another instance running, exiting"; exit 0; }

picklist_state_init

NOW=$(date +%s)
# Look back PICKLIST_OVERNIGHT_HOURS hours (default 13 = covers since ~6 PM yesterday)
SINCE=$(( NOW - PICKLIST_OVERNIGHT_HOURS * 3600 ))

log "=== picklist-ops/morning: starting at $(date -u '+%Y-%m-%dT%H:%M:%SZ') ==="
log "picklist-ops/morning: overnight window = last ${PICKLIST_OVERNIGHT_HOURS}h (since $(date -d "@${SINCE}" -u '+%Y-%m-%d %H:%M UTC' 2>/dev/null || date -r "${SINCE}" -u '+%Y-%m-%d %H:%M UTC'))"

if [[ -z "${PICKLIST_READY_STATUS_ID:-}" ]]; then
  log "picklist-ops/morning: ERROR — PICKLIST_READY_STATUS_ID not set."
  exit 1
fi

# ── Fetch ALL overnight orders — no limit ──────────────────────────────
# Morning batch intentionally ignores printed-orders state (reset the day).
# We DO reset the printed-orders list at the start of each morning run.
log "picklist-ops/morning: resetting printed-orders state for new day"
printf '[]' > "${PICKLIST_STATE_DIR}/printed-orders.json"
picklist_clear_timer

log "picklist-ops/morning: fetching all ready orders since ${SINCE}..."
all_orders=$(bl_get_orders "$SINCE" "$PICKLIST_READY_STATUS_ID" || printf '[]')
[[ -z "$all_orders" || "$all_orders" == "null" ]] && all_orders="[]"

order_count=$(printf '%s' "$all_orders" | jq 'length')
log "picklist-ops/morning: ${order_count} overnight orders found"

if [[ "$order_count" -eq 0 ]]; then
  log "picklist-ops/morning: no overnight orders — nothing to print"

  alert_create "info" "warehouse" "Picklists/Alerts" \
    "Morning picklist: no overnight orders" \
    "Morning batch ran at $(date -u '+%H:%M UTC') but found no orders with ready status.

Check BaseLinker for any orders that may not have reached ready status yet."
  exit 0
fi

# ── Generate morning batch (no PICKLIST_BATCH_SIZE cap) ───────────────
batch_id=$(picklist_batch_id "morning")
result=$(picklist_generate "$all_orders" "$batch_id" "morning")

log "picklist-ops/morning: batch generated — ${batch_id}"

print_url="${PICKLIST_SCAN_BASE_URL:-}/picklist/print/${batch_id}?autoprint=1"

alert_create "info" "warehouse" "Picklists/Alerts" \
  "Morning picklist ready: ${batch_id}" \
  "**Batch:** ${batch_id}
**Orders:** ${order_count}
**Type:** Morning batch (all overnight orders)
**Print:** [Open picklist](${print_url})

All overnight orders are included — no 25-order cap.
Scan QR codes at pack station after picking to trigger label printing."

log "=== picklist-ops/morning: complete — ${order_count} orders in batch ${batch_id} ==="
