#!/usr/bin/env bash
# marketplace-lib/config.sh — Shared constants and logging for marketplace ops
# Source this first in every skill script.

# ── Vault ──────────────────────────────────────────────────────────────
# OBSIDIAN_HOST is injected by Doppler as full URL (http://host:port)
VAULT_URL="${OBSIDIAN_HOST}"

# ── Paths ──────────────────────────────────────────────────────────────
CACHE_BASE="/opt/bigman-engine/cache/marketplace"
STATE_BASE="/opt/bigman-engine/state"

# ── API URLs ───────────────────────────────────────────────────────────
BASELINKER_API_URL="https://api.baselinker.com/connector.php"
QOGITA_API_URL="https://api.qogita.com"

# ── BaseLinker Rate Limit ──────────────────────────────────────────────
BL_RATE_LIMIT=100          # requests per minute
BL_RATE_LOCK="/tmp/bl-rate.lock"
BL_RATE_LOG="/tmp/bl-rate.log"

# ── Finance Thresholds ─────────────────────────────────────────────────
FINANCE_DISCREPANCY_HIGH=25
FINANCE_DISCREPANCY_CRITICAL=100
INVOICE_MATCH_TOLERANCE=0.50

# ── Compliance Thresholds ──────────────────────────────────────────────
COMPLIANCE_WARN_PERCENT=80
COMPLIANCE_CRITICAL_PERCENT=90
# BaseLinker order_status_id values that count as defects
# 121669=Cancelled, 127043=Label Error, 127045=Other Issues
COMPLIANCE_DEFECT_STATUSES="121669 127043 127045"

# ── Support Thresholds ─────────────────────────────────────────────────
SUPPORT_STALE_DAYS=5
COURIER_CLAIM_WINDOW_DAYS=14

# ── Graduation Thresholds ─────────────────────────────────────────────
GRADUATION_MIN_CASES=10
GRADUATION_APPROVAL_RATE=90
GRADUATION_MIN_DAYS=7

# ── Picklist Settings ──────────────────────────────────────────────────
# PICKLIST_READY_STATUS_ID: BaseLinker order_status_id meaning "Ready to Pick"
# Set in Doppler shared-services as PICKLIST_READY_STATUS_ID
PICKLIST_READY_STATUS_ID="${PICKLIST_READY_STATUS_ID:-}"

# Auto-batch fires when this many orders are ready (or time limit is reached)
PICKLIST_BATCH_SIZE="${PICKLIST_BATCH_SIZE:-25}"

# Time limit in seconds before forcing a partial batch (default: 1 hour)
PICKLIST_TIME_LIMIT_SECONDS="${PICKLIST_TIME_LIMIT_SECONDS:-3600}"

# Hours to look back for morning batch (covers overnight from ~6 PM the day before)
PICKLIST_OVERNIGHT_HOURS="${PICKLIST_OVERNIGHT_HOURS:-13}"

# State directory — must match the data/picklist path accessible to the event handler
PICKLIST_STATE_DIR="${PICKLIST_STATE_DIR:-/app/data/picklist}"

# Base URL for QR scan endpoint (e.g. https://bot.arrybarry.com)
# Set in Doppler shared-services as PICKLIST_SCAN_BASE_URL
PICKLIST_SCAN_BASE_URL="${PICKLIST_SCAN_BASE_URL:-}"

# ── Cache Defaults ─────────────────────────────────────────────────────
CACHE_DEFAULT_MAX_AGE=24   # hours
CACHE_ROTATION_DAYS=7

# ── Logging ────────────────────────────────────────────────────────────
log() {
  local msg="$1"
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" >&2
}

# ── Float comparison helpers (bc -l) ──────────────────────────────────
bc_gt() { [[ $(echo "$1 > $2" | bc -l 2>/dev/null) == "1" ]]; }
bc_lt() { [[ $(echo "$1 < $2" | bc -l 2>/dev/null) == "1" ]]; }
bc_eq() { [[ $(echo "$1 == $2" | bc -l 2>/dev/null) == "1" ]]; }
