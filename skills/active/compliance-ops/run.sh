#!/usr/bin/env bash
set -euo pipefail

# compliance-ops/run.sh — Account health and compliance monitoring
# Fetches orders, returns, and journal from BaseLinker, calculates defect
# rates per marketplace, and raises alerts on threshold breaches.
#
# Env: BASELINKER_API_TOKEN, OBSIDIAN_HOST, OBSIDIAN_API_KEY (via Doppler)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../marketplace-lib" && pwd)"

# ── Source shared libraries ────────────────────────────────────────────
source "$LIB_DIR/config.sh"
source "$LIB_DIR/cache.sh"
source "$LIB_DIR/baselinker.sh"
source "$LIB_DIR/alerts.sh"

LOCK_FILE="/tmp/compliance-ops.lock"
NOW_EPOCH=$(date +%s)
WINDOW_48H=$(( NOW_EPOCH - 48 * 3600 ))
TODAY=$(date -u '+%Y-%m-%d')

log "compliance-ops: starting run"

# ── Lockfile ───────────────────────────────────────────────────────────
exec 201>"$LOCK_FILE"
flock -n 201 || { log "compliance-ops: another instance running, exiting"; exit 0; }

# ════════════════════════════════════════════════════════════════════════
# PHASE 1 — FETCH
# ════════════════════════════════════════════════════════════════════════
log "phase-1: fetching data (48h window, since epoch ${WINDOW_48H})"

if journal=$(bl_get_journal "$WINDOW_48H"); then
  journal_count=$(printf '%s' "$journal" | jq 'length')
else
  log "phase-1: journal fetch failed (non-fatal), continuing"
  journal="[]"
  journal_count=0
fi
log "phase-1: journal entries: ${journal_count}"

# Use cached orders if fresh (< 2h), otherwise fetch
if cache_fresh "orders" "latest" 2; then
  orders=$(cache_read "orders" "latest" 2)
  [[ -z "$orders" ]] && orders="[]"
  order_count=$(printf '%s' "$orders" | jq 'length')
  log "phase-1: orders from cache: ${order_count}"
else
  orders=$(bl_get_orders "$WINDOW_48H" || printf '%s' "[]")
  [[ -z "$orders" ]] && orders="[]"
  order_count=$(printf '%s' "$orders" | jq 'length')
  log "phase-1: orders fetched: ${order_count}"
fi

returns=$(bl_get_returns "$WINDOW_48H" || printf '%s' "[]")
[[ -z "$returns" ]] && returns="[]"
return_count=$(printf '%s' "$returns" | jq 'length')
log "phase-1: returns: ${return_count}"

sources_raw=$(bl_get_order_sources)
log "phase-1: order sources fetched"

# Build platform_key -> display_name lookup
# order_source values are platform keys like "amazon", "ebay", "tiktok"
# sources structure: { sources: { platform: { id: storeName } } }
# Use capitalised platform key as display name (e.g. Amazon, Ebay, Tiktok)
sources_map=$(printf '%s' "$sources_raw" | jq -c '
  [.sources // {} | to_entries[] |
    {(.key): (.key | gsub("_"; " ") | split(" ") |
      map(if length > 0 then (.[:1] | ascii_upcase) + .[1:] else . end) |
      join(" "))}
  ] | add // {}')

log "phase-1: fetch complete — orders=${order_count} returns=${return_count} journal=${journal_count}"

# ════════════════════════════════════════════════════════════════════════
# PHASE 2 — ANALYSE
# ════════════════════════════════════════════════════════════════════════

# ── 2a: Defect rate calculation per marketplace ────────────────────────
log "phase-2a: calculating defect rates per marketplace"

# Build jq-friendly array of defect status IDs from config
defect_ids_json=$(printf '%s\n' $COMPLIANCE_DEFECT_STATUSES | jq -R 'tonumber' | jq -s '.')

# Group orders by order_source (platform key), count total and defective
defect_data=$(printf '%s' "$orders" | jq -c --argjson defect_ids "$defect_ids_json" '
  group_by(.order_source) |
  map({
    source_id:  (.[0].order_source | tostring),
    total:      length,
    defective:  [.[] | select(.order_status_id as $s | $defect_ids | index($s))] | length
  }) |
  sort_by(-.defective)')

alert_count=0

while IFS= read -r row; do
  source_id=$(printf '%s' "$row" | jq -r '.source_id')
  total=$(printf '%s' "$row" | jq -r '.total')
  defective=$(printf '%s' "$row" | jq -r '.defective')

  # Look up marketplace display name from sources map (keyed by platform like "amazon")
  marketplace=$(printf '%s' "$sources_map" | jq -r --arg id "$source_id" '.[$id] // empty')
  if [[ -z "$marketplace" || "$marketplace" == "null" ]]; then
    # Capitalise platform key as fallback (e.g. amazon -> Amazon)
    marketplace=$(printf '%s' "$source_id" | sed 's/./\U&/')
  fi

  # Skip if no orders
  if (( total == 0 )); then
    log "phase-2a: ${marketplace} — no orders, skipping"
    continue
  fi

  # Calculate defect rate using bc
  defect_rate=$(echo "scale=4; ${defective} * 100 / ${total}" | bc -l)

  # Threshold: 2.5% is the marketplace max. warn=80% of that, critical=90% of that.
  warn_threshold=$(echo "scale=4; 2.5 * ${COMPLIANCE_WARN_PERCENT} / 100" | bc -l)
  crit_threshold=$(echo "scale=4; 2.5 * ${COMPLIANCE_CRITICAL_PERCENT} / 100" | bc -l)

  log "phase-2a: ${marketplace} — ${defective}/${total} defects (${defect_rate}%), warn=${warn_threshold}%, crit=${crit_threshold}%"

  # Check critical first, then warn
  is_critical=$(echo "${defect_rate} >= ${crit_threshold}" | bc -l)
  is_warn=$(echo "${defect_rate} >= ${warn_threshold}" | bc -l)

  if (( is_critical )); then
    alert_create "critical" "$marketplace" "Compliance/Alerts" \
      "Critical defect rate: ${marketplace}" \
      "Defect rate **${defect_rate}%** exceeds critical threshold (${crit_threshold}%).

- **Orders (48h):** ${total}
- **Defective:** ${defective}
- **Rate:** ${defect_rate}%
- **Threshold:** ${crit_threshold}% (critical)

Immediate action required. Check marketplace seller dashboard for account health warnings."
    alert_count=$((alert_count + 1))
  elif (( is_warn )); then
    alert_create "high" "$marketplace" "Compliance/Alerts" \
      "Warning defect rate: ${marketplace}" \
      "Defect rate **${defect_rate}%** exceeds warning threshold (${warn_threshold}%).

- **Orders (48h):** ${total}
- **Defective:** ${defective}
- **Rate:** ${defect_rate}%
- **Threshold:** ${warn_threshold}% (warning)

Review recent cancellations and order issues to prevent further escalation."
    alert_count=$((alert_count + 1))
  fi
done < <(printf '%s' "$defect_data" | jq -c '.[]')

log "phase-2a: defect analysis complete — ${alert_count} alerts raised"

# ── 2b: Return rate analysis ──────────────────────────────────────────
log "phase-2b: calculating return rate"

if (( order_count > 0 )); then
  return_rate=$(echo "scale=4; ${return_count} * 100 / ${order_count}" | bc -l)
  log "phase-2b: overall return rate: ${return_count}/${order_count} = ${return_rate}%"

  is_high_returns=$(echo "${return_rate} > 10" | bc -l)
  if (( is_high_returns )); then
    alert_create "high" "All" "Compliance/Alerts" \
      "High return rate across orders" \
      "Overall return rate **${return_rate}%** exceeds 10% threshold.

- **Orders (48h):** ${order_count}
- **Returns (48h):** ${return_count}
- **Rate:** ${return_rate}%
- **Threshold:** 10%

Investigate common return reasons. Consider product quality, listing accuracy, and shipping damage."
    log "phase-2b: high return rate alert raised"
  fi
else
  log "phase-2b: no orders in window, skipping return rate"
fi

# ── 2c: Weekly health snapshot (Sundays only) ─────────────────────────
day_of_week=$(date '+%u')

if (( day_of_week == 7 )); then
  log "phase-2c: Sunday detected — generating weekly health snapshot"

  # Build per-marketplace summary lines
  marketplace_lines=""
  while IFS= read -r row; do
    source_id=$(printf '%s' "$row" | jq -r '.source_id')
    total=$(printf '%s' "$row" | jq -r '.total')
    defective=$(printf '%s' "$row" | jq -r '.defective')

    marketplace=$(printf '%s' "$sources_map" | jq -r --arg id "$source_id" '.[$id] // empty')
    if [[ -z "$marketplace" || "$marketplace" == "null" ]]; then
      marketplace=$(printf '%s' "$source_id" | sed 's/./\U&/')
    fi

    if (( total > 0 )); then
      rate=$(echo "scale=2; ${defective} * 100 / ${total}" | bc -l)
    else
      rate="0.00"
    fi

    marketplace_lines="${marketplace_lines}| ${marketplace} | ${total} | ${defective} | ${rate}% |
"
  done < <(printf '%s' "$defect_data" | jq -c '.[]')

  # Overall return rate for report
  if (( order_count > 0 )); then
    overall_return_rate=$(echo "scale=2; ${return_count} * 100 / ${order_count}" | bc -l)
  else
    overall_return_rate="0.00"
  fi

  # Determine overall health status
  health_status="healthy"
  if (( alert_count > 0 )); then
    health_status="warning"
  fi

  health_note="---
source: compliance-ops
type: weekly-health
date: ${TODAY}
severity: info
status: open
---

# Weekly Compliance Health Report — ${TODAY}

## Overall Status: ${health_status}

## Order Metrics (48h window)

- **Total orders:** ${order_count}
- **Total returns:** ${return_count}
- **Overall return rate:** ${overall_return_rate}%
- **Alerts raised this run:** ${alert_count}

## Defect Rates by Marketplace

| Marketplace | Orders | Defects | Rate |
|-------------|--------|---------|------|
${marketplace_lines}
## Thresholds

- **Defect warning:** ${COMPLIANCE_WARN_PERCENT}% of 2.5% = $(echo "scale=2; 2.5 * ${COMPLIANCE_WARN_PERCENT} / 100" | bc -l)%
- **Defect critical:** ${COMPLIANCE_CRITICAL_PERCENT}% of 2.5% = $(echo "scale=2; 2.5 * ${COMPLIANCE_CRITICAL_PERCENT} / 100" | bc -l)%
- **Return rate flag:** >10%

## Journal Activity

- **Journal entries (48h):** ${journal_count}

## Notes

_Auto-generated by compliance-ops. Review marketplace dashboards for full account health details._
"

  vault_path="07-Marketplace/Compliance/Health/${TODAY}-weekly-health.md"

  http_code=$(curl -sS -o /dev/null -w '%{http_code}' \
    -X PUT "${VAULT_URL}/vault/${vault_path}" \
    -H "Authorization: Bearer ${OBSIDIAN_API_KEY}" \
    -H "Content-Type: text/markdown" \
    -d "$health_note")

  if [[ "$http_code" == "204" || "$http_code" == "200" ]]; then
    log "phase-2c: weekly health snapshot written to ${vault_path}"
  else
    log "phase-2c: failed to write weekly health snapshot — HTTP ${http_code}"
  fi
else
  log "phase-2c: not Sunday (day=${day_of_week}), skipping weekly snapshot"
fi

# ── Done ───────────────────────────────────────────────────────────────
log "compliance-ops: run complete — orders=${order_count} returns=${return_count} alerts=${alert_count}"
