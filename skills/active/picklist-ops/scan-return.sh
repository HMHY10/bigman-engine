#!/usr/bin/env bash
set -euo pipefail
# picklist-ops/scan-return.sh — Triggered when a picker scans a completed picklist QR
#
# Called by the webhook trigger (TRIGGERS.json) when a POST arrives at
# /webhook/picklist-scan. The webhook body contains the picklist ID.
#
# Expected invocation from trigger:
#   bash /app/skills/active/picklist-ops/scan-return.sh '{"picklist_id":"PL-20260704-060012"}'
#   OR with URL query param format:
#   bash /app/skills/active/picklist-ops/scan-return.sh 'PL-20260704-060012'
#
# What this script does:
#   1. Parses the picklist ID from the argument
#   2. Loads picklist state (order IDs)
#   3. Prints a shipping label for each order via BaseLinker
#   4. Marks orders as BL_STATUS_PICKED in BaseLinker
#   5. Marks the picklist as completed in state + vault

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/picklist-lib.sh"

# ── Parse picklist ID ─────────────────────────────────────────────────
RAW_ARG="${1:-}"

if [[ -z "$RAW_ARG" ]]; then
  log "scan-return: ERROR — no argument provided"
  echo "Usage: $0 '<picklist_id or json body>'" >&2
  exit 1
fi

# Accept either raw picklist ID string or JSON body {"picklist_id":"PL-..."}
if printf '%s' "$RAW_ARG" | jq -e . >/dev/null 2>&1; then
  PICKLIST_ID=$(printf '%s' "$RAW_ARG" | jq -r '.picklist_id // .id // empty')
else
  # Raw string (could be from query param ?id=PL-...)
  PICKLIST_ID="$RAW_ARG"
fi

# Strip URL encoding if present
PICKLIST_ID=$(printf '%s' "$PICKLIST_ID" | python3 -c \
  'import sys, urllib.parse; print(urllib.parse.unquote(sys.stdin.read().strip()))' \
  2>/dev/null || printf '%s' "$PICKLIST_ID")

if [[ -z "$PICKLIST_ID" ]] || [[ ! "$PICKLIST_ID" =~ ^PL-[0-9]{8}-[0-9]{6}$ ]]; then
  log "scan-return: ERROR — invalid picklist ID: '${PICKLIST_ID}'"
  exit 1
fi

log "=== picklist-ops/scan-return: ${PICKLIST_ID} ==="

# ── Load picklist state ───────────────────────────────────────────────
STATE=$(pl_load_state "$PICKLIST_ID") || {
  log "scan-return: ERROR — state not found for ${PICKLIST_ID}"
  alert_create "high" "baselinker" "Picklists/Alerts" \
    "Scan Return Failed — Unknown Picklist" \
    "**Picklist ID:** ${PICKLIST_ID}

Picklist QR was scanned but no state file found. The picklist may have been
completed already or generated outside this system."
  exit 1
}

CURRENT_STATUS=$(printf '%s' "$STATE" | jq -r '.status // "unknown"')
ORDER_IDS=$(     printf '%s' "$STATE" | jq -c '.order_ids // []')
ORDER_COUNT=$(   printf '%s' "$ORDER_IDS" | jq 'length')

log "scan-return: ${ORDER_COUNT} orders, current status=${CURRENT_STATUS}"

if [[ "$CURRENT_STATUS" == "completed" ]]; then
  log "scan-return: ${PICKLIST_ID} already completed — skipping label reprint"
  printf 'Picklist %s already completed.\n' "$PICKLIST_ID"
  exit 0
fi

# ── Print shipping label for each order ──────────────────────────────
LABELS_OK=0
LABELS_FAILED=0

while IFS= read -r ORDER_ID; do
  [[ -z "$ORDER_ID" ]] && continue

  if pl_print_shipping_label "$ORDER_ID"; then
    LABELS_OK=$(( LABELS_OK + 1 ))
  else
    LABELS_FAILED=$(( LABELS_FAILED + 1 ))
    log "scan-return: label failed for order ${ORDER_ID}"
  fi

done < <(printf '%s' "$ORDER_IDS" | jq -r '.[]')

log "scan-return: labels — ok=${LABELS_OK} failed=${LABELS_FAILED}"

# ── Advance BaseLinker status to "picked" ─────────────────────────────
if [[ -n "${BL_STATUS_PICKED:-}" ]]; then
  while IFS= read -r ORDER_ID; do
    [[ -z "$ORDER_ID" ]] && continue
    pl_set_order_status "$ORDER_ID" "$BL_STATUS_PICKED" || true
  done < <(printf '%s' "$ORDER_IDS" | jq -r '.[]')
fi

# ── Mark picklist as completed ────────────────────────────────────────
pl_set_picklist_status "$PICKLIST_ID" "completed"

# ── Update vault note ─────────────────────────────────────────────────
COMPLETED_AT="$(date -u '+%Y-%m-%d %H:%M UTC')"
vault_write "07-Marketplace/Picklists/${PICKLIST_ID}.md" "$(cat <<VEOF
---
source: picklist-ops
type: picklist
picklist_id: ${PICKLIST_ID}
created: $(printf '%s' "$STATE" | jq -r '.created_at // ""')
completed: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
status: completed
orders: ${ORDER_COUNT}
labels_ok: ${LABELS_OK}
labels_failed: ${LABELS_FAILED}
---

# Picklist ${PICKLIST_ID}

**Status:** Completed
**Completed at:** ${COMPLETED_AT}
**Orders:** ${ORDER_COUNT}
**Labels printed:** ${LABELS_OK}
**Label failures:** ${LABELS_FAILED}

## Orders

$(printf '%s' "$ORDER_IDS" | jq -r 'map("- #\(.)") | join("\n")')
VEOF
)" || log "scan-return: vault write failed (non-critical)"

# ── Alert on partial label failure ────────────────────────────────────
if (( LABELS_FAILED > 0 )); then
  alert_create "high" "baselinker" "Picklists/Alerts" \
    "Shipping Label Failures — ${PICKLIST_ID}" \
    "**Picklist:** ${PICKLIST_ID}
**Orders total:** ${ORDER_COUNT}
**Labels printed:** ${LABELS_OK}
**Labels failed:** ${LABELS_FAILED}

${LABELS_FAILED} shipping label(s) failed to print after picklist return scan.
Check BaseLinker for orders without packages and re-run label generation manually."
fi

log "=== scan-return: ${PICKLIST_ID} complete — ${LABELS_OK}/${ORDER_COUNT} labels printed ==="
printf 'Picklist %s completed. Labels: %d/%d\n' "$PICKLIST_ID" "$LABELS_OK" "$ORDER_COUNT"
