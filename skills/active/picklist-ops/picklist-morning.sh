#!/usr/bin/env bash
set -euo pipefail

# picklist-ops/picklist-morning.sh — Morning batch: print ALL overnight ready orders at once
#
# Runs at 07:00 daily. Fetches all orders in ready status from the overnight window
# (default: last 14 hours = since ~5pm previous day). Generates a single large
# SKU-grouped picklist with no order cap — all overnight orders in one document.
# Resets any pending auto-batch window.
#
# Runs as: doppler run -p shared-services -c prd -- ./picklist-morning.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../marketplace-lib" && pwd)"

source "${LIB_DIR}/config.sh"
source "${LIB_DIR}/cache.sh"
source "${LIB_DIR}/baselinker.sh"
source "${LIB_DIR}/alerts.sh"
source "${SCRIPT_DIR}/picklist-lib.sh"

picklist_init

if [[ -z "${PICKLIST_READY_STATUS_ID:-}" ]]; then
  log "picklist-morning: PICKLIST_READY_STATUS_ID not set — skipping"
  exit 0
fi

log "=== picklist-morning: starting morning batch ==="

# Override look-back window for overnight coverage
export PICKLIST_SINCE_HOURS="$PICKLIST_MORNING_SINCE_HOURS"
log "Overnight window: last ${PICKLIST_MORNING_SINCE_HOURS}h"

# Clear any stale auto-batch window from overnight
batch_window_clear

# Delegate to generate in 'all' mode — no cap, SKU-grouped, all ready orders
exec "${SCRIPT_DIR}/picklist-generate.sh" all
