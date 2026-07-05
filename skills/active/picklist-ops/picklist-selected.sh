#!/usr/bin/env bash
set -euo pipefail

# picklist-ops/picklist-selected.sh — Manual "Print selected orders" button
#
# Generates a picklist for a specific set of order IDs.
# Accepts order IDs as arguments or parses them from a JSON/query-string body.
#
# Usage:
#   picklist-selected.sh 12345 67890 11111         (direct ID args)
#   picklist-selected.sh "12345,67890,11111"        (comma-separated string)
#   picklist-selected.sh '{"orders":"12345,67890"}' (JSON from webhook body)
#   echo '{"orders":[12345,67890]}' | picklist-selected.sh  (stdin)
#
# Triggered via:
#   - Webhook: POST ${BIGMAN_HOST}/webhook with body: {"action":"picklist-selected","orders":"ID1,ID2,..."}
#   - CLI: doppler run -p shared-services -c prd -- ./picklist-selected.sh ID1 ID2 ...

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../marketplace-lib" && pwd)"

source "${LIB_DIR}/config.sh"
source "${SCRIPT_DIR}/picklist-lib.sh"

picklist_init

# ── Parse order IDs ────────────────────────────────────────────────────
ORDER_IDS=()

INPUT="${1:-}"

# Try stdin if single arg looks like JSON/body or no args
if [[ -z "$INPUT" ]] && ! [ -t 0 ]; then
  INPUT=$(cat)
fi

if [[ $# -gt 1 ]]; then
  # Multiple numeric arguments
  while [[ $# -gt 0 ]]; do
    ARG=$(printf '%s' "$1" | tr -cd '0-9,')
    IFS=',' read -ra PARTS <<< "$ARG"
    for p in "${PARTS[@]}"; do
      [[ -n "$p" ]] && ORDER_IDS+=("$p")
    done
    shift
  done
elif [[ -n "$INPUT" ]]; then
  # Single argument — could be JSON, comma-separated, or single ID
  if printf '%s' "$INPUT" | jq -e '.orders' >/dev/null 2>&1; then
    # JSON object with 'orders' field (array or comma string)
    ORDERS_VAL=$(printf '%s' "$INPUT" | jq -r '.orders')
    if printf '%s' "$ORDERS_VAL" | jq -e 'type == "array"' >/dev/null 2>&1; then
      while IFS= read -r id; do
        ORDER_IDS+=("$id")
      done < <(printf '%s' "$ORDERS_VAL" | jq -r '.[]')
    else
      IFS=',' read -ra PARTS <<< "$ORDERS_VAL"
      for p in "${PARTS[@]}"; do
        CLEAN=$(printf '%s' "$p" | tr -cd '0-9')
        [[ -n "$CLEAN" ]] && ORDER_IDS+=("$CLEAN")
      done
    fi
  else
    # Comma-separated or single numeric
    CLEAN=$(printf '%s' "$INPUT" | tr -cd '0-9,')
    IFS=',' read -ra PARTS <<< "$CLEAN"
    for p in "${PARTS[@]}"; do
      [[ -n "$p" ]] && ORDER_IDS+=("$p")
    done
  fi
fi

if (( ${#ORDER_IDS[@]} == 0 )); then
  log "picklist-selected: ERROR — no order IDs provided"
  log "Usage: picklist-selected.sh ID1 ID2 ... OR pass JSON body with 'orders' field"
  exit 1
fi

log "=== picklist-selected: manual print for ${#ORDER_IDS[@]} orders ==="
log "Order IDs: ${ORDER_IDS[*]}"

exec "${SCRIPT_DIR}/picklist-generate.sh" ids "${ORDER_IDS[@]}"
