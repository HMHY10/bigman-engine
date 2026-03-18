#!/usr/bin/env bash
set -euo pipefail

# ── Source shared libs ───────────────────────────────────────────────
LIB="/opt/bigman-engine/skills/active/marketplace-lib"
source "${LIB}/config.sh"
source "${LIB}/cache.sh"
source "${LIB}/baselinker.sh"
source "${LIB}/alerts.sh"

SKILL="support-ops"
log "${SKILL}: starting run"

# ── Time window: 72 hours ───────────────────────────────────────────
SINCE=$(( $(date +%s) - 72 * 3600 ))
NOW_EPOCH=$(date +%s)

# =====================================================================
# PHASE 1 — FETCH
# =====================================================================
log "${SKILL}: phase 1 — fetch"

RETURNS_JSON=$(bl_get_returns "$SINCE")
RETURNS_COUNT=$(printf '%s' "$RETURNS_JSON" | jq 'length')
log "${SKILL}: fetched ${RETURNS_COUNT} returns (72h window)"

# Orders are fetched to disk cache (can be huge — 300k+ lines).
# bl_get_orders writes to cache; we read from the cache file to avoid
# holding the entire dataset in a bash variable.
ORDERS_CACHE="${CACHE_BASE}/orders/latest.json"

if (( RETURNS_COUNT > 0 )); then
  # Only fetch orders when we have returns to analyse against.
  # bl_get_orders can fail on very large datasets (bash variable overflow);
  # catch failure and fall back to whatever was cached.
  bl_get_orders "$SINCE" > /dev/null 2>&1 || log "${SKILL}: orders fetch incomplete — using cached data"
  ORDERS_COUNT=$(jq 'length' "$ORDERS_CACHE" 2>/dev/null || echo 0)
else
  # No returns — check if we have a recent cache, otherwise skip
  if cache_fresh "orders" "latest" 4; then
    ORDERS_COUNT=$(jq 'length' "$ORDERS_CACHE" 2>/dev/null || echo 0)
  else
    ORDERS_COUNT=0
  fi
fi
log "${SKILL}: ${ORDERS_COUNT} orders available for analysis"

# =====================================================================
# PHASE 2 — ANALYSE
# =====================================================================
log "${SKILL}: phase 2 — analyse"

ALERT_COUNT=0

# ── 2a: Stale return detection ──────────────────────────────────────
log "${SKILL}: 2a — stale return detection"

STALE_THRESHOLD_SECS=$(( SUPPORT_STALE_DAYS * 86400 ))

while read -r return_id order_id created_at status; do
  [[ -z "$return_id" ]] && continue

  # Skip completed/resolved/closed returns
  status_lower=$(printf '%s' "$status" | tr '[:upper:]' '[:lower:]')
  case "$status_lower" in
    completed|resolved|closed|refunded) continue ;;
  esac

  # Calculate age
  age_secs=$(( NOW_EPOCH - created_at ))
  age_days=$(( age_secs / 86400 ))

  if (( age_secs > STALE_THRESHOLD_SECS )); then
    log "${SKILL}: stale return detected — return_id=${return_id} order_id=${order_id} age=${age_days}d"

    alert_body="Return **#${return_id}** (order #${order_id}) has been open for **${age_days} days** without resolution.

**Status:** ${status}
**Created:** $(date -u -d "@${created_at}" '+%Y-%m-%d %H:%M UTC' 2>/dev/null || date -u -r "${created_at}" '+%Y-%m-%d %H:%M UTC')
**Age:** ${age_days} days (threshold: ${SUPPORT_STALE_DAYS} days)

> Action needed: investigate why this return has not progressed.

\`\`\`yaml
return_id: ${return_id}
order_id: ${order_id}
\`\`\`"

    alert_create "high" "all" "Support/Alerts" \
      "Stale Return ${return_id}" \
      "$alert_body" && ALERT_COUNT=$((ALERT_COUNT + 1))
  fi
done < <(printf '%s' "$RETURNS_JSON" | jq -r '.[] | "\(.return_id) \(.order_id) \(.date) \(.status // "unknown")"')

log "${SKILL}: 2a complete — ${ALERT_COUNT} stale return alerts"

# ── 2b: Repeat customer detection ──────────────────────────────────
log "${SKILL}: 2b — repeat customer detection"

REPEAT_BEFORE=$ALERT_COUNT

# Build email -> return count mapping from returns
# Each return has an order_id; look up customer email from orders
# First, build an order_id -> email lookup
declare -A ORDER_EMAIL_MAP
if [[ -f "$ORDERS_CACHE" ]]; then
  while read -r oid email; do
    [[ -z "$oid" || -z "$email" || "$email" == "null" ]] && continue
    ORDER_EMAIL_MAP["$oid"]="$email"
  done < <(jq -r '.[] | "\(.order_id) \(.email // "null")"' "$ORDERS_CACHE")
fi

# Now count returns per email
declare -A EMAIL_RETURN_COUNT
declare -A EMAIL_RETURN_IDS
while read -r return_id order_id; do
  [[ -z "$return_id" ]] && continue
  email="${ORDER_EMAIL_MAP[${order_id}]:-unknown}"
  [[ "$email" == "unknown" || "$email" == "null" ]] && continue

  current_count="${EMAIL_RETURN_COUNT[${email}]:-0}"
  EMAIL_RETURN_COUNT["$email"]=$(( current_count + 1 ))

  existing_ids="${EMAIL_RETURN_IDS[${email}]:-}"
  if [[ -n "$existing_ids" ]]; then
    EMAIL_RETURN_IDS["$email"]="${existing_ids}, ${return_id}"
  else
    EMAIL_RETURN_IDS["$email"]="${return_id}"
  fi
done < <(printf '%s' "$RETURNS_JSON" | jq -r '.[] | "\(.return_id) \(.order_id)"')

# Flag customers with 3+ returns
for email in "${!EMAIL_RETURN_COUNT[@]}"; do
  count="${EMAIL_RETURN_COUNT[$email]}"
  if (( count >= 3 )); then
    return_ids="${EMAIL_RETURN_IDS[$email]}"
    log "${SKILL}: repeat customer — ${email} has ${count} returns"

    alert_body="Customer **${email}** has **${count} returns** in the last 72 hours.

**Return IDs:** ${return_ids}

> Possible serial returner — review account history and consider flagging.

\`\`\`yaml
customer_email: ${email}
return_count: ${count}
window: 72h
\`\`\`"

    alert_create "high" "all" "Support/Alerts" \
      "Repeat Returner ${email}" \
      "$alert_body" && ALERT_COUNT=$((ALERT_COUNT + 1))
  fi
done

REPEAT_ALERTS=$(( ALERT_COUNT - REPEAT_BEFORE ))
log "${SKILL}: 2b complete — ${REPEAT_ALERTS} repeat customer alerts"

# ── 2c: Product return rate analysis ────────────────────────────────
log "${SKILL}: 2c — product return rate analysis"

PRODUCT_BEFORE=$ALERT_COUNT

# Count returns per product (using product name or SKU from return items)
declare -A PRODUCT_RETURN_COUNT
declare -A PRODUCT_NAMES

while read -r sku name; do
  [[ -z "$sku" || "$sku" == "null" ]] && continue
  current="${PRODUCT_RETURN_COUNT[${sku}]:-0}"
  PRODUCT_RETURN_COUNT["$sku"]=$(( current + 1 ))
  if [[ -n "$name" && "$name" != "null" ]]; then
    PRODUCT_NAMES["$sku"]="$name"
  fi
done < <(printf '%s' "$RETURNS_JSON" | jq -r '.[] | .items[]? | "\(.sku // .product_id // "unknown") \(.name // "unknown")"')

# Count orders per product
declare -A PRODUCT_ORDER_COUNT
if [[ -f "$ORDERS_CACHE" ]]; then
  while read -r sku; do
    [[ -z "$sku" || "$sku" == "null" ]] && continue
    current="${PRODUCT_ORDER_COUNT[${sku}]:-0}"
    PRODUCT_ORDER_COUNT["$sku"]=$(( current + 1 ))
  done < <(jq -r '.[] | .products[]? | (.sku // .product_id // "unknown")' "$ORDERS_CACHE")
fi

# Flag products with 3+ returns and >10% return rate
for sku in "${!PRODUCT_RETURN_COUNT[@]}"; do
  ret_count="${PRODUCT_RETURN_COUNT[$sku]}"
  (( ret_count < 3 )) && continue

  ord_count="${PRODUCT_ORDER_COUNT[${sku}]:-0}"
  (( ord_count == 0 )) && continue

  return_rate=$(echo "scale=2; ${ret_count} * 100 / ${ord_count}" | bc -l)
  exceeds=$(echo "${return_rate} > 10" | bc -l)

  if (( exceeds == 1 )); then
    product_name="${PRODUCT_NAMES[${sku}]:-${sku}}"
    log "${SKILL}: high return rate — ${sku} (${product_name}): ${ret_count}/${ord_count} = ${return_rate}%"

    alert_body="Product **${product_name}** (SKU: ${sku}) has a return rate of **${return_rate}%**.

| Metric | Value |
|--------|-------|
| Returns (72h) | ${ret_count} |
| Orders (72h) | ${ord_count} |
| Return Rate | ${return_rate}% |

> Investigate product quality, listing accuracy, or packaging issues.

\`\`\`yaml
sku: ${sku}
product_name: ${product_name}
return_count: ${ret_count}
order_count: ${ord_count}
return_rate_pct: ${return_rate}
\`\`\`"

    alert_create "high" "all" "Support/Alerts" \
      "High Return Rate ${sku}" \
      "$alert_body" && ALERT_COUNT=$((ALERT_COUNT + 1))
  fi
done

PRODUCT_ALERTS=$(( ALERT_COUNT - PRODUCT_BEFORE ))
log "${SKILL}: 2c complete — ${PRODUCT_ALERTS} product return rate alerts"

# ── Summary ─────────────────────────────────────────────────────────
log "${SKILL}: run complete — ${RETURNS_COUNT} returns, ${ORDERS_COUNT} orders, ${ALERT_COUNT} alerts raised"
