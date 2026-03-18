#!/usr/bin/env bash
set -euo pipefail

# finance-ops/run.sh — Financial intelligence for marketplace operations
# Runs as: doppler run -p shared-services -c prd -- ./run.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../marketplace-lib" && pwd)"

# Source shared libraries
source "${LIB_DIR}/config.sh"
source "${LIB_DIR}/cache.sh"
source "${LIB_DIR}/baselinker.sh"
source "${LIB_DIR}/alerts.sh"

STATE_DIR="${STATE_BASE}/finance-ops"
mkdir -p "$STATE_DIR"

log "=== finance-ops: starting run ==="

# ── PHASE 1: FETCH ──────────────────────────────────────────────────

SINCE_48H=$(( $(date +%s) - 172800 ))  # 48 hours ago

log "Fetching orders (last 48h)..."
ORDERS=$(bl_get_orders "$SINCE_48H" || printf '%s' "[]")
[[ -z "$ORDERS" ]] && ORDERS="[]"
ORDER_COUNT=$(printf '%s' "$ORDERS" | jq 'length')
log "Orders fetched: ${ORDER_COUNT}"

log "Fetching returns (last 48h)..."
RETURNS=$(bl_get_returns "$SINCE_48H" || printf '%s' "[]")
[[ -z "$RETURNS" ]] && RETURNS="[]"
RETURN_COUNT=$(printf '%s' "$RETURNS" | jq 'length')
log "Returns fetched: ${RETURN_COUNT}"

log "Fetching journal events..."
JOURNAL=$(bl_get_journal "$SINCE_48H" || printf '%s' "[]")
[[ -z "$JOURNAL" ]] && JOURNAL="[]"
JOURNAL_COUNT=$(printf '%s' "$JOURNAL" | jq 'length')
log "Journal events: ${JOURNAL_COUNT}"

log "Fetching sales invoices (last 48h)..."
INVOICES_RAW=$(bl_get_invoices "$SINCE_48H" || printf '%s' '{"invoices":[]}')
[[ -z "$INVOICES_RAW" ]] && INVOICES_RAW='{"invoices":[]}'
INVOICES=$(printf '%s' "$INVOICES_RAW" | jq -c '.invoices // []')
INVOICE_COUNT=$(printf '%s' "$INVOICES" | jq 'length')
log "Sales invoices: ${INVOICE_COUNT}"

log "Fetching purchase orders..."
POS_RAW=$(bl_get_purchase_orders || printf '%s' '{"purchase_orders":[]}')
[[ -z "$POS_RAW" ]] && POS_RAW='{"purchase_orders":[]}'
POS=$(printf '%s' "$POS_RAW" | jq -c '.purchase_orders // .orders // []')
PO_COUNT=$(printf '%s' "$POS" | jq 'length')
log "Purchase orders: ${PO_COUNT}"

log "Fetching inventory documents (goods-in)..."
DOCS_RAW=$(bl_get_inventory_documents || printf '%s' '{"documents":[]}')
[[ -z "$DOCS_RAW" ]] && DOCS_RAW='{"documents":[]}'
DOCS=$(printf '%s' "$DOCS_RAW" | jq -c '.documents // []')
DOC_COUNT=$(printf '%s' "$DOCS" | jq 'length')
log "Inventory documents: ${DOC_COUNT}"

# Extract package IDs from orders for courier status lookup
PACKAGE_IDS=$(printf '%s' "$ORDERS" | jq -c '[.[].packages[]?.package_id // empty] | unique')
PACKAGE_COUNT=$(printf '%s' "$PACKAGE_IDS" | jq 'length')
log "Unique packages to check: ${PACKAGE_COUNT}"

COURIER_STATUS="{}"
if (( PACKAGE_COUNT > 0 )); then
  log "Fetching courier status for ${PACKAGE_COUNT} packages..."
  COURIER_STATUS=$(bl_get_courier_status "$PACKAGE_IDS" || printf '%s' "{}")
  [[ -z "$COURIER_STATUS" ]] && COURIER_STATUS="{}"
  log "Courier status fetched"
fi

# ── PHASE 2: ANALYSE ────────────────────────────────────────────────

log "Starting analysis..."

# ── Pre-fetch: Payment cache ──────────────────────────────────────
# Build payment cache for all order IDs referenced by returns (deduped).
# Avoids N+1 API calls in refund reconciliation and courier claims.
log "Pre-fetching payment history for return-related orders..."

declare -A PAYMENT_CACHE
PAYMENT_FETCH_COUNT=0
while IFS= read -r oid; do
  [[ -z "$oid" || "$oid" == "null" ]] && continue
  [[ -n "${PAYMENT_CACHE[$oid]+x}" ]] && continue  # already fetched
  PAYMENT_CACHE[$oid]=$(bl_get_order_payments "$oid" 2>/dev/null || printf '%s' '{"payments":[]}')
  PAYMENT_FETCH_COUNT=$((PAYMENT_FETCH_COUNT + 1))
done < <(printf '%s' "$RETURNS" | jq -r '.[].order_id' | sort -u)
log "Payment cache built: ${PAYMENT_FETCH_COUNT} unique orders"

# ── 2a: Refund Reconciliation ──────────────────────────────────────
# For each return, get order payments. Flag: return exists but no refund,
# or refund amount doesn't match return value.
log "Analysing refund reconciliation..."

REFUND_ALERT_COUNT=0
while IFS= read -r ret; do
  [[ -z "$ret" ]] && continue

  ret_return_id=$(printf '%s' "$ret" | jq -r '.return_id')
  ret_order_id=$(printf '%s' "$ret" | jq -r '.order_id')
  ret_status=$(printf '%s' "$ret" | jq -r '.status // "unknown"')

  # Get payment history from cache
  PAYMENTS_RAW="${PAYMENT_CACHE[$ret_order_id]:-{"payments":[]}}"
  PAYMENTS=$(printf '%s' "$PAYMENTS_RAW" | jq -c '.payments // []')

  # Sum refund payments
  REFUND_TOTAL=$(printf '%s' "$PAYMENTS" | jq '[.[] | select(.type == "refund" or .type == "REFUND") | (.amount // 0 | tonumber)] | add // 0')

  # Sum return product values
  RETURN_VALUE=$(printf '%s' "$ret" | jq '[.products // [] | .[].price // 0 | tonumber] | add // 0')

  # Case 1: Return exists but no refund at all
  if bc_eq "$REFUND_TOTAL" 0 && bc_gt "$RETURN_VALUE" 0; then
    DIFF="$RETURN_VALUE"
    if bc_gt "$DIFF" "$FINANCE_DISCREPANCY_HIGH"; then
      sev="high"
      if bc_gt "$DIFF" "$FINANCE_DISCREPANCY_CRITICAL"; then
        sev="critical"
      fi

      alert_create "$sev" "baselinker" "Finance/Alerts" \
        "Unreconciled Return ${ret_return_id} No Refund" \
        "**Order:** ${ret_order_id}
**Return ID:** ${ret_return_id}
**Return value:** GBP ${RETURN_VALUE}
**Refund issued:** GBP 0.00
**Status:** ${ret_status}

Return filed but no matching refund payment found. Verify if refund is pending or was missed."

      REFUND_ALERT_COUNT=$((REFUND_ALERT_COUNT + 1))
    fi
  fi

  # Case 2: Refund amount doesn't match return value
  if bc_gt "$REFUND_TOTAL" 0 && bc_gt "$RETURN_VALUE" 0; then
    MISMATCH=$(echo "scale=2; $RETURN_VALUE - $REFUND_TOTAL" | bc -l)
    # Take absolute value
    ABS_MISMATCH=$(echo "if ($MISMATCH < 0) -1 * $MISMATCH else $MISMATCH" | bc -l)

    if bc_gt "$ABS_MISMATCH" "$FINANCE_DISCREPANCY_HIGH"; then
      sev="high"
      if bc_gt "$ABS_MISMATCH" "$FINANCE_DISCREPANCY_CRITICAL"; then
        sev="critical"
      fi

      alert_create "$sev" "baselinker" "Finance/Alerts" \
        "Refund Mismatch Return ${ret_return_id}" \
        "**Order:** ${ret_order_id}
**Return ID:** ${ret_return_id}
**Return value:** GBP ${RETURN_VALUE}
**Refund issued:** GBP ${REFUND_TOTAL}
**Discrepancy:** GBP ${ABS_MISMATCH}
**Status:** ${ret_status}

Refund amount does not match return value. Discrepancy exceeds threshold."

      REFUND_ALERT_COUNT=$((REFUND_ALERT_COUNT + 1))
    fi
  fi

done < <(printf '%s' "$RETURNS" | jq -c '.[]')

log "Refund reconciliation complete: ${REFUND_ALERT_COUNT} alerts raised"

# ── 2b: PO-to-Delivery Matching ───────────────────────────────────
log "Analysing PO-to-delivery matching..."

read -r PO_ALERT_COUNT _po_short _po_late <<< "$(bl_check_po_delivery "$POS" "$DOCS" "Finance/Alerts")"

log "PO-to-delivery matching complete: ${PO_ALERT_COUNT} alerts raised"

# ── 2c: Courier Claims Detection ──────────────────────────────────
# Check courier status for lost/damaged parcels. Flag parcels needing
# claims filed (approaching COURIER_CLAIM_WINDOW_DAYS). Cross-reference
# with customer refunds.
log "Analysing courier claims..."

COURIER_ALERT_COUNT=0
if (( PACKAGE_COUNT > 0 )); then
  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue

    pkg_id=$(printf '%s' "$pkg" | jq -r '.key')
    pkg_statuses=$(printf '%s' "$pkg" | jq '.value')
    latest_status=$(printf '%s' "$pkg_statuses" | jq -r 'if type == "array" then .[-1].status // "unknown" else "unknown" end')

    # Flag lost or damaged parcels
    if printf '%s' "$latest_status" | grep -qi "lost\|damaged\|undelivered\|missing"; then
      # Check how old the last status change is
      status_date=$(printf '%s' "$pkg_statuses" | jq -r 'if type == "array" then .[-1].date // .[-1].timestamp // 0 else 0 end')
      if [[ "$status_date" =~ ^[0-9]+$ ]] && (( status_date > 0 )); then
        age_days=$(( ($(date +%s) - status_date) / 86400 ))
      else
        age_days=0
      fi

      sev="high"
      # Claim window closing soon (within 3 days of deadline)
      if (( age_days >= COURIER_CLAIM_WINDOW_DAYS - 3 )); then
        sev="critical"
      fi

      # Cross-reference: find the order for this package to check refund status
      pkg_order_id=$(printf '%s' "$ORDERS" | jq -r --arg pid "$pkg_id" \
        '[.[] | select(.packages[]?.package_id == ($pid | tonumber) or .packages[]?.package_id == $pid)] | .[0].order_id // "unknown"')

      refund_note=""
      if [[ "$pkg_order_id" != "unknown" ]]; then
        # Use payment cache if available, otherwise fetch and cache
        if [[ -z "${PAYMENT_CACHE[$pkg_order_id]+x}" ]]; then
          PAYMENT_CACHE[$pkg_order_id]=$(bl_get_order_payments "$pkg_order_id" 2>/dev/null || printf '%s' '{"payments":[]}')
        fi
        pkg_payments_raw="${PAYMENT_CACHE[$pkg_order_id]}"
        pkg_refund=$(printf '%s' "$pkg_payments_raw" | jq '[.payments // [] | .[] | select(.type == "refund" or .type == "REFUND") | (.amount // 0 | tonumber)] | add // 0')
        if bc_gt "$pkg_refund" 0; then
          refund_note="
**Customer refund issued:** GBP ${pkg_refund} — courier claim required to recoup cost."
        fi
      fi

      alert_create "$sev" "baselinker" "Finance/Claims" \
        "Courier Claim Needed Package ${pkg_id}" \
        "**Package ID:** ${pkg_id}
**Latest status:** ${latest_status}
**Days since status:** ${age_days}
**Claim window:** ${COURIER_CLAIM_WINDOW_DAYS} days
**Related order:** ${pkg_order_id}${refund_note}

Parcel appears lost/damaged. File courier claim before window expires."

      COURIER_ALERT_COUNT=$((COURIER_ALERT_COUNT + 1))
    fi

  done < <(printf '%s' "$COURIER_STATUS" | jq -c 'to_entries[]?')
fi

log "Courier claims detection complete: ${COURIER_ALERT_COUNT} alerts raised"

# ── 2d: Daily P&L Snapshot ─────────────────────────────────────────
# Aggregate orders by marketplace source. Calculate revenue, refund
# totals, net per marketplace. Write to vault.
log "Generating daily P&L..."
DATE_STR=$(date '+%Y-%m-%d')

# Calculate refund totals from returns
TOTAL_REFUND_VALUE=$(printf '%s' "$RETURNS" | jq '[.[].products // [] | .[].price // 0 | tonumber] | add // 0')

# Aggregate orders by source
PNL_BODY=$(printf '%s' "$ORDERS" | jq -r '
  group_by(.order_source) |
  map({
    source: (.[0].order_source // "unknown"),
    count: length,
    revenue: (map(.payment_done // 0 | tonumber) | add // 0),
    items: (map(.products // [] | length) | add // 0)
  }) |
  sort_by(-.revenue) |
  .[] |
  "| \(.source) | \(.count) | \(.revenue | . * 100 | round / 100) | \(.items) |"
')

# Calculate total revenue
TOTAL_REVENUE=$(printf '%s' "$ORDERS" | jq '[.[].payment_done // 0 | tonumber] | add // 0')
NET_REVENUE=$(echo "scale=2; $TOTAL_REVENUE - $TOTAL_REFUND_VALUE" | bc -l)

PNL_CONTENT="---
source: finance-ops
type: daily-pnl
date: ${DATE_STR}
severity: info
status: report
total_revenue: ${TOTAL_REVENUE}
total_refunds: ${TOTAL_REFUND_VALUE}
net_revenue: ${NET_REVENUE}
---

# Daily P&L Summary - ${DATE_STR}

| Source | Orders | Revenue (GBP) | Items |
|--------|--------|---------------|-------|
${PNL_BODY}

## Totals

- **Total orders (48h window):** ${ORDER_COUNT}
- **Total returns (48h window):** ${RETURN_COUNT}
- **Total invoices (48h window):** ${INVOICE_COUNT}
- **Gross revenue:** GBP ${TOTAL_REVENUE}
- **Return value:** GBP ${TOTAL_REFUND_VALUE}
- **Net revenue:** GBP ${NET_REVENUE}

---
*Auto-generated by finance-ops at $(date -u '+%Y-%m-%d %H:%M:%S UTC')*"

# Write P&L to vault
PNL_PATH="07-Marketplace/Finance/Reports/${DATE_STR}-daily-pnl.md"
vault_write "$PNL_PATH" "$PNL_CONTENT" || log "Daily P&L write failed"

# ── 2e: Stale Claims Check ─────────────────────────────────────────
# Read existing open claims from vault 07-Marketplace/Finance/Claims/.
# Escalate claims older than 7 days with no status change. Track
# last_escalated timestamp to prevent re-alerting every run.
log "Checking for stale claims..."

STALE_CLAIM_COUNT=0
CLAIMS_RESPONSE=$(curl -sS \
  "${VAULT_URL}/vault/07-Marketplace/Finance/Claims/" \
  -H "Authorization: Bearer ${OBSIDIAN_API_KEY}" 2>/dev/null || printf '%s' "")

if [[ -n "$CLAIMS_RESPONSE" ]]; then
  while IFS= read -r claim_file; do
    [[ -z "$claim_file" ]] && continue
    [[ "$claim_file" == *".gitkeep"* ]] && continue

    # Fetch claim note content
    CLAIM_CONTENT=$(curl -sS \
      "${VAULT_URL}/vault/07-Marketplace/Finance/Claims/${claim_file}" \
      -H "Authorization: Bearer ${OBSIDIAN_API_KEY}" \
      -H "Accept: text/markdown" 2>/dev/null || printf '%s' "")

    [[ -z "$CLAIM_CONTENT" ]] && continue

    # Only process open claims
    if printf '%s' "$CLAIM_CONTENT" | grep -q "^status: open"; then
      # Extract date and last_escalated from frontmatter
      CLAIM_DATE=$(printf '%s' "$CLAIM_CONTENT" | grep "^date:" | head -1 | awk '{print $2}')
      LAST_ESC=$(printf '%s' "$CLAIM_CONTENT" | grep "^last_escalated:" | head -1 | awk '{print $2}')
      CHECK_DATE="${LAST_ESC:-$CLAIM_DATE}"

      if [[ -n "$CHECK_DATE" ]]; then
        # Calculate days since last check date (portable: try GNU date then BSD date)
        CHECK_EPOCH=$(date -d "$CHECK_DATE" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$CHECK_DATE" +%s 2>/dev/null || printf '%s' "0")
        if (( CHECK_EPOCH > 0 )); then
          DAYS_SINCE=$(( ($(date +%s) - CHECK_EPOCH) / 86400 ))

          if (( DAYS_SINCE >= 7 )); then
            log "Stale claim detected: ${claim_file} (${DAYS_SINCE} days since last update)"

            # Update the claim: escalate severity and record escalation timestamp
            TODAY=$(date '+%Y-%m-%d')

            if printf '%s' "$CLAIM_CONTENT" | grep -q "^last_escalated:"; then
              # Replace existing last_escalated
              UPDATED_CONTENT=$(printf '%s' "$CLAIM_CONTENT" | sed "s/^last_escalated: .*/last_escalated: ${TODAY}/")
            else
              # Add last_escalated after status line
              UPDATED_CONTENT=$(printf '%s' "$CLAIM_CONTENT" | sed "/^status: open/a\\
last_escalated: ${TODAY}")
            fi

            # Escalate severity to critical
            UPDATED_CONTENT=$(printf '%s' "$UPDATED_CONTENT" | sed 's/^severity: high$/severity: critical/')

            # Write updated content back to vault
            if vault_write "07-Marketplace/Finance/Claims/${claim_file}" "$UPDATED_CONTENT"; then
              log "Stale claim escalated: ${claim_file}"
            else
              log "Stale claim escalation failed: ${claim_file}"
            fi

            STALE_CLAIM_COUNT=$((STALE_CLAIM_COUNT + 1))
          fi
        fi
      fi
    fi

  done < <(printf '%s' "$CLAIMS_RESPONSE" | jq -r '.files[]? // empty')
fi

log "Stale claims check complete: ${STALE_CLAIM_COUNT} claims escalated"

# ── Summary ────────────────────────────────────────────────────────

TOTAL_ALERTS=$((REFUND_ALERT_COUNT + PO_ALERT_COUNT + COURIER_ALERT_COUNT))

log "=== finance-ops: run complete ==="
log "  Orders: ${ORDER_COUNT} | Returns: ${RETURN_COUNT} | Invoices: ${INVOICE_COUNT}"
log "  POs: ${PO_COUNT} | Goods-in docs: ${DOC_COUNT} | Packages: ${PACKAGE_COUNT}"
log "  Alerts raised: ${TOTAL_ALERTS} (refund: ${REFUND_ALERT_COUNT}, PO: ${PO_ALERT_COUNT}, courier: ${COURIER_ALERT_COUNT})"
log "  Stale claims escalated: ${STALE_CLAIM_COUNT}"
