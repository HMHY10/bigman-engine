#!/usr/bin/env bash
set -euo pipefail

# picklist-ops/picklist-next.sh — Manual "Print next 25" button
#
# Immediately generates a picklist with the next PICKLIST_BATCH_SIZE unprinted
# ready orders, bypassing the auto-batch window timer.
#
# Triggered via:
#   - Webhook: POST/GET ${BIGMAN_HOST}/webhook?action=picklist-next
#   - CLI: doppler run -p shared-services -c prd -- ./picklist-next.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../marketplace-lib" && pwd)"

source "${LIB_DIR}/config.sh"
source "${SCRIPT_DIR}/picklist-lib.sh"

picklist_init
log "=== picklist-next: manual 'Print next ${PICKLIST_BATCH_SIZE}' triggered ==="

exec "${SCRIPT_DIR}/picklist-generate.sh" batch "${PICKLIST_BATCH_SIZE}"
